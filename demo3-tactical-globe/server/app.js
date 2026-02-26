/**
 * GEOINT Tactical Globe — Express + WebSocket Server
 * Serves CesiumJS globe application and pushes simulated tactical data.
 */

const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const path = require('path');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

app.use(express.static(path.join(__dirname, 'public')));
app.use(express.json());

// Broadcast to all connected clients
function broadcast(data) {
    const message = JSON.stringify(data);
    wss.clients.forEach(client => {
        if (client.readyState === WebSocket.OPEN) {
            client.send(message);
        }
    });
}

// Health endpoint
app.get('/api/health', (req, res) => {
    res.json({ status: 'healthy', service: 'tactical-globe', clients: wss.clients.size });
});

// Accept detection results from Demo 1 and broadcast to globe clients
app.post('/api/detections', (req, res) => {
    const detections = req.body;
    broadcast({ type: 'detection_update', timestamp: new Date().toISOString(), detections });
    res.json({ status: 'ok', broadcast: wss.clients.size });
});

// Simulated entity state
const entities = {
    aircraft: [
        { id: 'ac-001', type: 'UAV', lat: 38.89, lon: -77.04, alt: 3000, heading: 45, speed: 120 },
        { id: 'ac-002', type: 'ISR', lat: 38.87, lon: -77.06, alt: 8000, heading: 180, speed: 250 },
    ],
    vehicles: [
        { id: 'vh-001', type: 'patrol', lat: 38.88, lon: -77.03, heading: 90, speed: 30 },
        { id: 'vh-002', type: 'logistics', lat: 38.86, lon: -77.05, heading: 270, speed: 45 },
    ],
    vessels: [
        { id: 'vs-001', type: 'patrol_boat', lat: 38.86, lon: -77.04, heading: 135, speed: 15 },
    ],
};

// Update entity positions
function updateEntities() {
    Object.values(entities).flat().forEach(entity => {
        const headingRad = (entity.heading * Math.PI) / 180;
        const speedFactor = entity.speed * 0.00001;
        entity.lat += Math.cos(headingRad) * speedFactor;
        entity.lon += Math.sin(headingRad) * speedFactor;
        // Random heading adjustments
        entity.heading += (Math.random() - 0.5) * 10;
        entity.heading = ((entity.heading % 360) + 360) % 360;
    });

    broadcast({
        type: 'entity_update',
        timestamp: new Date().toISOString(),
        entities: entities,
    });
}

// Simulated alerts
function generateAlert() {
    const alertTypes = ['detection', 'boundary_crossing', 'anomaly', 'status_change'];
    const alert = {
        type: 'alert',
        alertType: alertTypes[Math.floor(Math.random() * alertTypes.length)],
        timestamp: new Date().toISOString(),
        message: 'Simulated tactical alert',
        location: {
            lat: 38.85 + Math.random() * 0.05,
            lon: -77.06 + Math.random() * 0.04,
        },
    };
    broadcast(alert);
}

// Update loop
setInterval(updateEntities, 1000);
setInterval(generateAlert, 15000);

const PORT = process.env.PORT || 8085;
server.listen(PORT, () => {
    console.log(`Tactical Globe server running on port ${PORT}`);
});
