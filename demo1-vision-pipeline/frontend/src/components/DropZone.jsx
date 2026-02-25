import { useRef, useState, useCallback } from 'react';

export default function DropZone({ onFileSelect }) {
  const [dragover, setDragover] = useState(false);
  const inputRef = useRef(null);

  const handleDrag = useCallback((e) => {
    e.preventDefault();
    e.stopPropagation();
  }, []);

  const handleDragIn = useCallback((e) => {
    e.preventDefault();
    e.stopPropagation();
    setDragover(true);
  }, []);

  const handleDragOut = useCallback((e) => {
    e.preventDefault();
    e.stopPropagation();
    setDragover(false);
  }, []);

  const handleDrop = useCallback(
    (e) => {
      e.preventDefault();
      e.stopPropagation();
      setDragover(false);
      const files = e.dataTransfer?.files;
      if (files?.length > 0 && files[0].type.startsWith('image/')) {
        onFileSelect(files[0]);
      }
    },
    [onFileSelect]
  );

  const handleClick = () => inputRef.current?.click();

  const handleChange = (e) => {
    const file = e.target.files?.[0];
    if (file) onFileSelect(file);
  };

  return (
    <div
      className={`dropzone ${dragover ? 'dragover' : ''}`}
      onDragOver={handleDrag}
      onDragEnter={handleDragIn}
      onDragLeave={handleDragOut}
      onDrop={handleDrop}
      onClick={handleClick}
    >
      <div className="dropzone-icon">🛰️</div>
      <h2>Drop satellite imagery here</h2>
      <p>or click to browse for an image file</p>
      <span className="dropzone-hint">
        Supports JPEG, PNG, TIFF · Max 20 MB
      </span>
      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        onChange={handleChange}
        style={{ display: 'none' }}
      />
    </div>
  );
}
