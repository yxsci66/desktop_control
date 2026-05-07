import asyncio
import json
import os
import sys
import threading
import time
from fractions import Fraction
from typing import List

import cv2
import numpy as np
import pyautogui
import websockets
from aiortc import (
    RTCPeerConnection,
    RTCSessionDescription,
    VideoStreamTrack,
    RTCConfiguration,
    RTCIceServer,
)
from aiortc.contrib.media import MediaBlackhole
from mss import mss  # 使用 mss 进行屏幕捕获，更可靠

# ---------- Video Capture Track ----------
class ScreenVideoTrack(VideoStreamTrack):
    """A video track that captures the screen using pyautogui and yields JPEG frames."""

    def __init__(self, fps: int = 15):
        super().__init__()  # don't forget this!
        self.fps = fps
        self.frame_interval = 1.0 / fps
        self._last_timestamp = None
        self.sct = mss()  # 使用 mss 进行屏幕捕获

    async def recv(self):
        print('[ScreenVideoTrack] recv() called')
        try:
            # Throttle to the desired fps
            now = time.time()
            if self._last_timestamp is None:
                self._last_timestamp = now
            else:
                wait = self.frame_interval - (now - self._last_timestamp)
                if wait > 0:
                    await asyncio.sleep(wait)
                self._last_timestamp = time.time()

            # Capture screen using mss (more reliable than pyautogui)
            print('[ScreenVideoTrack] Capturing screen...')
            # 使用主显示器（monitors[1]），如果不存在则使用所有显示器
            if len(self.sct.monitors) > 1:
                monitor = self.sct.monitors[1]
            else:
                monitor = self.sct.monitors[0]
            img = self.sct.grab(monitor)
            # 转换为 numpy 数组 (BGRA 格式)
            frame = np.array(img)
            # 将 BGRA 转换为 BGR
            frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
            print(f'[ScreenVideoTrack] Frame captured: {frame.shape}')
            # Build VideoFrame from BGR array; WebRTC will handle encoding
            from av import VideoFrame
            video_frame = VideoFrame.from_ndarray(frame, format='bgr24')
            video_frame.pts = int(time.time() * 1e6)
            # time_base 可选，使用默认值
            print(f'[ScreenVideoTrack] Generated frame: {frame.shape}')
            return video_frame
        except Exception as e:
            print(f'[ScreenVideoTrack] Error: {e}')
            import traceback
            traceback.print_exc()
            raise

# ---------- Signaling via WebSocket ----------
SIGNAL_URL = os.getenv('SIGNAL_URL', 'ws://127.0.0.1:8080')

async def signaling(pc: RTCPeerConnection, ws):
    print('--- HOST signaling started ---')
    # websockets library exposes the connection state via "state"
    print('WebSocket state:', ws.state)
    # Forward ICE candidates from the peer connection to the signaling server
    @pc.on('icecandidate')
    async def on_icecandidate(event):
        if event.candidate is not None:
            await ws.send(json.dumps({
                'type': 'candidate',
                'candidate': {
                    'candidate': event.candidate.sdp,
                    'sdpMid': event.candidate.sdpMid,
                    'sdpMLineIndex': event.candidate.sdpMLineIndex,
                }
            }))

    async for message in ws:
        data = json.loads(message)
        if data.get('type') == 'offer':
            print('Host received offer')
            print('Setting remote description...')
            await pc.setRemoteDescription(RTCSessionDescription(sdp=data['sdp'], type=data['type']))
            print('Remote description set, creating answer...')
            # 视频轨道已在 run() 中添加，此处无需重复添加
            answer = await pc.createAnswer()
            print(f'Answer created, SDP contains video: {"m=video" in answer.sdp}')
            await pc.setLocalDescription(answer)
            print('Local description set, sending answer...')
            await ws.send(json.dumps({'type': pc.localDescription.type, 'sdp': pc.localDescription.sdp}));
            print('Host sent answer')
        elif data.get('type') == 'candidate':
            print('Host received candidate:', data['candidate'])
            candidate = data['candidate']
            from aiortc import RTCIceCandidate
            cand_str = candidate['candidate']
            # 移除开头的 "candidate:" 前缀
            if cand_str.startswith('candidate:'):
                cand_str = cand_str[len('candidate:'):]
            parts = cand_str.split()
            # 正确字段顺序: foundation, component, protocol, priority, ip, port, "typ", type
            foundation = parts[0]
            component = int(parts[1])
            protocol = parts[2]
            priority = int(parts[3])
            ip = parts[4]
            port = int(parts[5])
            # parts[6] 是 "typ" 字面量，parts[7] 是实际类型
            typ = parts[7] if len(parts) > 7 else 'host'
            # aiortc RTCIceCandidate 必选参数顺序: component, foundation, ip, port, priority, protocol, type
            ice_candidate = RTCIceCandidate(
                component,
                foundation,
                ip,
                port,
                priority,
                protocol,
                typ,
                sdpMid=candidate['sdpMid'],
                sdpMLineIndex=candidate['sdpMLineIndex']
            )
            await pc.addIceCandidate(ice_candidate)
            print('Host added ICE candidate successfully')
        else:
            print('Unknown message:', data)

def handle_control(payload: dict):
    """Execute mouse / keyboard actions received from the client.
    Expected payload format example:
        {"action": "move", "x": 100, "y": 200}
        {"action": "click", "button": "left"}
        {"action": "type", "text": "hello"}
    """
    action = payload.get('action')
    if action == 'move':
        x = payload.get('x')
        y = payload.get('y')
        if x is not None and y is not None:
            pyautogui.moveTo(x, y)
    elif action == 'click':
        button = payload.get('button', 'left')
        pyautogui.click(button=button)
    elif action == 'type':
        text = payload.get('text', '')
        pyautogui.typewrite(text)
    else:
        print('Unsupported control action:', action)

async def run():
    # 正确创建 RTCConfiguration 对象
    config = RTCConfiguration(
        iceServers=[RTCIceServer(urls=["stun:stun.l.google.com:19302"])]
    )
    pc = RTCPeerConnection(configuration=config)
    
    # 立即添加视频轨道（在收到 offer 之前就添加）
    video_track = ScreenVideoTrack()
    sender = pc.addTrack(video_track)
    print(f'Added video track: {video_track}, sender: {sender}')
    
    # Keep a media sink to avoid warnings about unused tracks
    blackhole = MediaBlackhole()

    @pc.on('iceconnectionstatechange')
    async def on_iceconnectionstatechange():
        print('ICE connection state (host):', pc.iceConnectionState)
        if pc.iceConnectionState in ['completed', 'connected']:
            print('ICE connection established on host side!')

    @pc.on('track')
    async def on_track(track):
        print('Received remote track:', track.kind)
        await blackhole.start()

    @pc.on('datachannel')
    def on_datachannel(channel):
        print('DataChannel established:', channel.label)

        @channel.on('open')
        def on_open():
            # 获取屏幕分辨率并发送给客户端
            try:
                with mss() as sct:
                    monitor = sct.monitors[1] if len(sct.monitors) > 1 else sct.monitors[0]
                    screen_width = monitor['width']
                    screen_height = monitor['height']
                    print(f'Host screen size: {screen_width}x{screen_height}')
                    message = json.dumps({
                        'type': 'screen_info',
                        'width': screen_width,
                        'height': screen_height
                    })
                    channel.send(message)
                    print('Sent screen_info to client')
            except Exception as e:
                print(f'Error getting screen size: {e}')

        @channel.on('message')
        def on_message(message):
            if isinstance(message, str):
                try:
                    data = json.loads(message)
                    if data.get('type') == 'control':
                        handle_control(data['payload'])
                except Exception as e:
                    print('Error handling control message:', e)

    async with websockets.connect(SIGNAL_URL) as ws:
        print('Connected to signal server:', SIGNAL_URL)
        # Register as host
        await ws.send(json.dumps({'type': 'register', 'role': 'host'}))
        await signaling(pc, ws)

if __name__ == '__main__':
    # Ensure the script runs in a user session (not as a service)
    if not os.getenv('SESSIONNAME'):
        print('Warning: Running outside of a logged‑in user session may prevent screen capture.')
    asyncio.run(run())
