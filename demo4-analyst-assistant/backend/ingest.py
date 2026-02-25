"""Ingest sample GEOINT reports into ChromaDB vector store."""

import os
import glob
import chromadb

CHROMA_URL = os.getenv("CHROMA_URL", "http://localhost:8000")
REPORTS_DIR = os.getenv("REPORTS_DIR", "data/sample-reports")


def ingest_reports():
    client = chromadb.HttpClient(
        host=CHROMA_URL.replace("http://", "").split(":")[0],
        port=int(CHROMA_URL.split(":")[-1]),
    )

    collection = client.get_or_create_collection(
        name="geoint_reports",
        metadata={"description": "Sample GEOINT intelligence reports for demo"},
    )

    report_files = glob.glob(os.path.join(REPORTS_DIR, "*.txt"))
    if not report_files:
        print(f"No report files found in {REPORTS_DIR}")
        return

    documents = []
    metadatas = []
    ids = []

    for filepath in report_files:
        with open(filepath, "r") as f:
            content = f.read()

        filename = os.path.basename(filepath)
        doc_id = filename.replace(".txt", "")

        # Split into chunks (~500 chars each)
        chunks = [content[i:i+500] for i in range(0, len(content), 450)]

        for j, chunk in enumerate(chunks):
            documents.append(chunk)
            metadatas.append({
                "source_file": filename,
                "chunk_index": j,
                "total_chunks": len(chunks),
            })
            ids.append(f"{doc_id}-chunk-{j}")

    collection.upsert(documents=documents, metadatas=metadatas, ids=ids)
    print(f"Ingested {len(documents)} chunks from {len(report_files)} reports")


if __name__ == "__main__":
    ingest_reports()
