import { useRef, useEffect } from 'react';

export default function ImageCanvas({ imageSrc, detections, classColors }) {
  const canvasRef = useRef(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');

    const img = new Image();
    img.onload = () => {
      canvas.width = img.naturalWidth;
      canvas.height = img.naturalHeight;
      ctx.drawImage(img, 0, 0);

      // Draw bounding boxes
      detections.forEach((det) => {
        const [x1, y1, x2, y2] = det.bbox;
        const color = classColors[det.class] || '#0078d4';
        const w = x2 - x1;
        const h = y2 - y1;

        // Box outline
        ctx.strokeStyle = color;
        ctx.lineWidth = 3;
        ctx.strokeRect(x1, y1, w, h);

        // Semi-transparent fill
        ctx.fillStyle = color.replace(')', ', 0.08)').replace('rgb', 'rgba');
        if (color.startsWith('#')) {
          const r = parseInt(color.slice(1, 3), 16);
          const g = parseInt(color.slice(3, 5), 16);
          const b = parseInt(color.slice(5, 7), 16);
          ctx.fillStyle = `rgba(${r},${g},${b},0.08)`;
        }
        ctx.fillRect(x1, y1, w, h);

        // Label background
        const label = `${det.class} ${Math.round(det.confidence * 100)}%`;
        ctx.font = 'bold 14px Segoe UI, system-ui, sans-serif';
        const textMetrics = ctx.measureText(label);
        const labelW = textMetrics.width + 12;
        const labelH = 22;

        ctx.fillStyle = color;
        ctx.fillRect(x1, y1 - labelH, labelW, labelH);

        // Label text
        ctx.fillStyle = '#000';
        ctx.fillText(label, x1 + 6, y1 - 6);

        // Corner accents
        const cornerLen = Math.min(12, w / 4, h / 4);
        ctx.strokeStyle = color;
        ctx.lineWidth = 3;
        // Top-left
        ctx.beginPath();
        ctx.moveTo(x1, y1 + cornerLen);
        ctx.lineTo(x1, y1);
        ctx.lineTo(x1 + cornerLen, y1);
        ctx.stroke();
        // Top-right
        ctx.beginPath();
        ctx.moveTo(x2 - cornerLen, y1);
        ctx.lineTo(x2, y1);
        ctx.lineTo(x2, y1 + cornerLen);
        ctx.stroke();
        // Bottom-left
        ctx.beginPath();
        ctx.moveTo(x1, y2 - cornerLen);
        ctx.lineTo(x1, y2);
        ctx.lineTo(x1 + cornerLen, y2);
        ctx.stroke();
        // Bottom-right
        ctx.beginPath();
        ctx.moveTo(x2 - cornerLen, y2);
        ctx.lineTo(x2, y2);
        ctx.lineTo(x2, y2 - cornerLen);
        ctx.stroke();
      });
    };
    img.src = imageSrc;
  }, [imageSrc, detections, classColors]);

  return (
    <div className="canvas-container">
      <canvas ref={canvasRef} />
      {detections.length > 0 && (
        <div className="canvas-toolbar">
          <span style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
            {detections.length} detection{detections.length !== 1 ? 's' : ''} ·{' '}
            {[...new Set(detections.map((d) => d.class))].length} class
            {[...new Set(detections.map((d) => d.class))].length !== 1 ? 'es' : ''}
          </span>
        </div>
      )}
    </div>
  );
}
