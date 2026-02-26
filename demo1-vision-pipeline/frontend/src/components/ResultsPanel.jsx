export default function ResultsPanel({ results, error, classColors }) {
  if (!results && !error) {
    return (
      <div className="empty-state">
        <div className="icon">📡</div>
        <p>Upload an image or load a sample to run the AI detection pipeline.</p>
      </div>
    );
  }

  const detections = results?.detections || [];
  // Handle analysis as string or object with text/choices
  let analysis = results?.analysis || '';
  if (typeof analysis === 'object') {
    analysis = analysis.text || analysis.choices?.[0]?.message?.content || JSON.stringify(analysis);
  }

  // Count detections by class (support both 'class' and 'class_name' keys)
  const counts = {};
  detections.forEach((d) => {
    const cls = d.class || d.class_name || 'unknown';
    counts[cls] = (counts[cls] || 0) + 1;
  });

  const classOrder = ['vehicle', 'aircraft', 'ship', 'building'];
  const sortedClasses = classOrder.filter((c) => c in counts);
  // Include any extra classes not in the predefined order
  Object.keys(counts).forEach((c) => {
    if (!sortedClasses.includes(c)) sortedClasses.push(c);
  });

  return (
    <div className="results-panel">
      {/* Error notice */}
      {error && (
        <div style={{
          background: 'rgba(255, 23, 68, 0.1)',
          border: '1px solid rgba(255, 23, 68, 0.3)',
          borderRadius: 8,
          padding: '10px 14px',
          marginBottom: 16,
          fontSize: 13,
          color: '#ff6e7e',
        }}>
          ⚠ API unavailable — showing demo data. {error}
        </div>
      )}

      {/* Detection Summary */}
      <h3>Detection Summary</h3>
      <div className="summary-grid">
        {sortedClasses.map((cls) => (
          <div className="summary-card" key={cls}>
            <div className="dot" style={{ background: classColors[cls] || '#0078d4' }} />
            <div>
              <div className="label">{cls}</div>
            </div>
            <div className="count">{counts[cls]}</div>
          </div>
        ))}
        <div className="summary-card total-card">
          <div className="dot" style={{ background: 'var(--accent)' }} />
          <div>
            <div className="label">Total Objects</div>
          </div>
          <div className="count">{detections.length}</div>
        </div>
      </div>

      {/* AI Analysis */}
      {analysis && (
        <>
          <h3>AI Analysis</h3>
          <div className="analysis-box">
            {analysis}
          </div>
        </>
      )}

      {/* Individual Detections */}
      {detections.length > 0 && (
        <>
          <h3>Detections</h3>
          <div className="detection-list">
            {detections.map((det, i) => {
              const cls = det.class || det.class_name || 'unknown';
              const bboxStr = Array.isArray(det.bbox)
                ? det.bbox.join(', ')
                : det.bbox ? `${det.bbox.x1}, ${det.bbox.y1}, ${det.bbox.x2}, ${det.bbox.y2}` : '';
              return (
              <div className="detection-card" key={i}>
                <div
                  className="class-dot"
                  style={{ background: classColors[cls] || '#0078d4' }}
                />
                <span className="class-name">{cls}</span>
                <span className="coords">
                  [{bboxStr}]
                </span>
                <span className="confidence">
                  {Math.round(det.confidence * 100)}%
                </span>
              </div>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
}
