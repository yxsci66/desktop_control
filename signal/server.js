const WebSocket = require('ws');

const PORT = process.env.PORT || 8080;
const wss = new WebSocket.Server({ port: PORT });

let host = null;
let client = null;

wss.on('connection', (ws) => {
  console.log('New connection');
  ws.on('message', (msg) => {
    try {
      const data = JSON.parse(msg);

      if (data.type === 'register') {
        console.log(`[SIGNAL] Register message: role=${data.role}`);
        if (data.role === 'host') {
          host = ws;
          ws.role = 'host';
          console.log('Host registered');
          if (client && client.readyState === WebSocket.OPEN) {
            client.send(JSON.stringify({ type: 'host_ready' }));
          }
        } else if (data.role === 'client') {
          client = ws;
          ws.role = 'client';
          console.log('Client registered');
          if (host && host.readyState === WebSocket.OPEN) {
            host.send(JSON.stringify({ type: 'client_ready' }));
          }
        }
        return;
      }

      const signalingTypes = ['offer', 'answer', 'candidate'];
      if (signalingTypes.includes(data.type)) {
        console.log(`[SIGNAL] Forwarding ${data.type} from ${ws.role} to ${ws.role === 'host' ? 'client' : 'host'}`);
        if (ws.role === 'host' && client && client.readyState === WebSocket.OPEN) {
          console.log('Forwarding', data.type, 'to client');
          client.send(JSON.stringify(data));
        } else if (ws.role === 'client' && host && host.readyState === WebSocket.OPEN) {
          console.log('Forwarding', data.type, 'to host');
          host.send(JSON.stringify(data));
        }
      }
    } catch (e) {
      console.error('Error processing message:', e);
    }
  });

  ws.on('close', () => {
    if (ws.role === 'host') {
      host = null;
      console.log('Host disconnected');
    } else if (ws.role === 'client') {
      client = null;
      console.log('Client disconnected');
    }
  });

  ws.on('error', (err) => {
    console.error('WebSocket error:', err);
  });
});

console.log(`Signal server listening on ws://0.0.0.0:${PORT}`);
