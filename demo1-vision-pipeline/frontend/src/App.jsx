import { useState, useEffect, useRef, useCallback } from 'react';
import DropZone from './components/DropZone';
import ImageCanvas from './components/ImageCanvas';
import ResultsPanel from './components/ResultsPanel';

const API_BASE = import.meta.env.VITE_API_URL || '';
const KIOSK_INTERVAL = 30000;

const CLASS_COLORS = {
  vehicle: '#00c853',
  aircraft: '#00bcd4',
  ship: '#ffd600',
  building: '#ff9100',
};

export default function App() {
  const [image, setImage] = useState(null);       // { src: dataURL, file: File }
  const [results, setResults] = useState(null);    // API response
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [showSamples, setShowSamples] = useState(false);
  const [samples, setSamples] = useState([]);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [kioskActive, setKioskActive] = useState(false);
  const kioskTimer = useRef(null);
  const idleTimer = useRef(null);

  // Load sample manifest
  useEffect(() => {
    fetch('/samples/sample-manifest.json')
      .then((r) => r.json())
      .then((data) => setSamples(data.samples || []))
      .catch(() => {});
  }, []);

  // Reset idle timer on user interaction
  const resetIdle = useCallback(() => {
    if (idleTimer.current) clearTimeout(idleTimer.current);
    setKioskActive(false);
    if (kioskTimer.current) clearInterval(kioskTimer.current);

    idleTimer.current = setTimeout(() => {
      if (samples.length > 0) setKioskActive(true);
    }, KIOSK_INTERVAL * 2);
  }, [samples]);

  useEffect(() => {
    window.addEventListener('mousemove', resetIdle);
    window.addEventListener('keydown', resetIdle);
    window.addEventListener('click', resetIdle);
    resetIdle();
    return () => {
      window.removeEventListener('mousemove', resetIdle);
      window.removeEventListener('keydown', resetIdle);
      window.removeEventListener('click', resetIdle);
    };
  }, [resetIdle]);

  // Kiosk auto-cycle
  useEffect(() => {
    if (!kioskActive || samples.length === 0) return;
    let idx = 0;
    const cycle = () => {
      const sample = samples[idx % samples.length];
      handleSampleSelect(sample);
      idx++;
    };
    cycle();
    kioskTimer.current = setInterval(cycle, KIOSK_INTERVAL);
    return () => clearInterval(kioskTimer.current);
  }, [kioskActive]); // eslint-disable-line react-hooks/exhaustive-deps

  async function runPipeline(file) {
    setLoading(true);
    setError(null);
    setResults(null);
    try {
      const formData = new FormData();
      formData.append('image', file);
      const res = await fetch(`${API_BASE}/api/pipeline`, { method: 'POST', body: formData });
      if (!res.ok) throw new Error(`API error: ${res.status}`);
      const data = await res.json();
      setResults(data);
    } catch (e) {
      setError(e.message);
      // Generate mock results for demo when API is unavailable
      setResults(generateMockResults());
    } finally {
      setLoading(false);
    }
  }

  function generateMockResults() {
    return {
      detections: [
        { class: 'vehicle', confidence: 0.94, bbox: [120, 200, 180, 260] },
        { class: 'vehicle', confidence: 0.87, bbox: [300, 210, 370, 275] },
        { class: 'aircraft', confidence: 0.96, bbox: [450, 100, 600, 200] },
        { class: 'building', confidence: 0.91, bbox: [50, 350, 200, 480] },
        { class: 'building', confidence: 0.82, bbox: [600, 340, 740, 470] },
        { class: 'ship', confidence: 0.89, bbox: [350, 400, 480, 470] },
      ],
      analysis:
        'Satellite imagery analysis reveals a mixed-use area with military and civilian infrastructure. Two vehicles detected near a road intersection, one fixed-wing aircraft on a runway apron, two multi-story buildings in an urban cluster, and one medium-sized vessel docked at a waterfront facility. Activity patterns suggest routine operations with no anomalous indicators.',
    };
  }

  function handleFileSelect(file) {
    const reader = new FileReader();
    reader.onload = (e) => {
      setImage({ src: e.target.result, file });
      runPipeline(file);
    };
    reader.readAsDataURL(file);
    resetIdle();
  }

  function handleSampleSelect(sample) {
    // Try to load the sample image; if unavailable, create a placeholder
    const img = new Image();
    img.onload = () => {
      setImage({ src: `/samples/${sample.filename}`, file: null });
      // Generate mock results for sample images
      setResults(generateMockResults());
      setLoading(false);
    };
    img.onerror = () => {
      // Create a placeholder canvas for missing sample images
      const canvas = document.createElement('canvas');
      canvas.width = 800;
      canvas.height = 600;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#1a1a2e';
      ctx.fillRect(0, 0, 800, 600);
      ctx.fillStyle = '#0078d4';
      ctx.font = '20px Segoe UI, system-ui';
      ctx.textAlign = 'center';
      ctx.fillText(sample.name, 400, 280);
      ctx.fillStyle = '#666';
      ctx.font = '14px Segoe UI, system-ui';
      ctx.fillText('Sample satellite imagery placeholder', 400, 320);
      const dataUrl = canvas.toDataURL();
      setImage({ src: dataUrl, file: null });
      setResults(generateMockResults());
      setLoading(false);
    };
    img.src = `/samples/${sample.filename}`;
    setShowSamples(false);
    setLoading(true);
    setError(null);
  }

  function handleReset() {
    setImage(null);
    setResults(null);
    setError(null);
    resetIdle();
  }

  function toggleFullscreen() {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen();
      setIsFullscreen(true);
    } else {
      document.exitFullscreen();
      setIsFullscreen(false);
    }
  }

  return (
    <div className={isFullscreen ? 'fullscreen' : ''}>
      {/* Header */}
      <header className="header">
        <div className="header-left">
          <h1>🛰️ GEOINT AI Vision Pipeline</h1>
          <span className="badge badge-azure">Azure Local</span>
          <span className="badge badge-live">LIVE</span>
        </div>
        <div className="header-actions">
          <button className="btn" onClick={() => setShowSamples(true)}>
            📂 Load Sample
          </button>
          {image && (
            <button className="btn" onClick={handleReset}>
              ✕ Clear
            </button>
          )}
          <button className="btn" onClick={toggleFullscreen}>
            {isFullscreen ? '⊡ Exit' : '⊞ Fullscreen'}
          </button>
        </div>
      </header>

      {/* Main content */}
      <div className="main">
        {/* Left panel — Image */}
        <div className="panel-left">
          {!image ? (
            <DropZone onFileSelect={handleFileSelect} />
          ) : (
            <ImageCanvas
              imageSrc={image.src}
              detections={results?.detections || []}
              classColors={CLASS_COLORS}
            />
          )}
          {loading && (
            <div className="loading-overlay">
              <div className="spinner" />
              <p>Running AI detection pipeline…</p>
            </div>
          )}
        </div>

        {/* Right panel — Results */}
        <div className="panel-right">
          <ResultsPanel
            results={results}
            error={error}
            classColors={CLASS_COLORS}
          />
        </div>
      </div>

      {/* Status bar */}
      <div className="status-bar">
        <span>
          {image ? 'Image loaded' : 'Awaiting input'} · API: {API_BASE}
        </span>
        {kioskActive && (
          <span className="kiosk-indicator">● KIOSK MODE — auto-cycling</span>
        )}
      </div>

      {/* Sample modal */}
      {showSamples && (
        <div className="modal-overlay" onClick={() => setShowSamples(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h2>Load Sample Image</h2>
            {samples.map((s) => (
              <div key={s.id} className="sample-item" onClick={() => handleSampleSelect(s)}>
                <h3>{s.name}</h3>
                <p>{s.description}</p>
              </div>
            ))}
            {samples.length === 0 && (
              <p style={{ color: 'var(--text-muted)', fontSize: 14 }}>
                No sample images configured.
              </p>
            )}
            <button className="btn modal-close" onClick={() => setShowSamples(false)}>
              Close
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
