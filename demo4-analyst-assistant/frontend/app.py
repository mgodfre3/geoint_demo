"""GEOINT Analyst Assistant — Streamlit Chat UI"""

import os
import requests
import streamlit as st

API_URL = os.getenv("API_URL", "http://localhost:8087")

st.set_page_config(
    page_title="GEOINT Analyst Assistant",
    page_icon="🌍",
    layout="wide",
)

# Custom styling
st.markdown("""
<style>
    .stApp { background-color: #0a0a0a; }
    .main-header {
        background: linear-gradient(135deg, #1a1a2e, #16213e);
        padding: 16px 24px; border-radius: 8px; margin-bottom: 24px;
        border-bottom: 2px solid #0078d4;
    }
    .source-card {
        background: #1a1a2e; border: 1px solid #333; border-radius: 8px;
        padding: 12px; margin: 4px 0; font-size: 13px;
    }
</style>
""", unsafe_allow_html=True)

st.markdown("""
<div class="main-header">
    <h1 style="color: white; margin: 0;">🌍 GEOINT Analyst Assistant</h1>
    <p style="color: #aaa; margin: 4px 0 0 0;">
        Powered by Foundry Local on Azure Local &nbsp;|&nbsp;
        <span style="color: #00c853;">● Connected</span>
    </p>
</div>
""", unsafe_allow_html=True)

# Chat interface
if "messages" not in st.session_state:
    st.session_state.messages = []

col1, col2 = st.columns([2, 1])

with col1:
    st.subheader("Chat")

    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])

    if prompt := st.chat_input("Ask about geospatial intelligence..."):
        st.session_state.messages.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)

        with st.chat_message("assistant"):
            with st.spinner("Analyzing..."):
                try:
                    response = requests.post(
                        f"{API_URL}/chat",
                        json={"message": prompt},
                        timeout=120,
                    )
                    if response.status_code == 200:
                        data = response.json()
                        st.markdown(data["response"])
                        st.session_state.messages.append({"role": "assistant", "content": data["response"]})
                        st.session_state["last_sources"] = data.get("sources", [])
                    else:
                        st.error("Failed to get response from analyst assistant.")
                except requests.exceptions.ConnectionError:
                    st.error("Cannot connect to assistant API. Ensure the backend is running.")

with col2:
    st.subheader("Sources")
    sources = st.session_state.get("last_sources", [])
    if sources:
        for src in sources:
            st.markdown(f"""
            <div class="source-card">
                <strong>{src.get('id', 'Unknown')}</strong><br>
                {src.get('text', 'No preview available')}
            </div>
            """, unsafe_allow_html=True)
    else:
        st.caption("Sources from intelligence reports will appear here after your first query.")

    st.subheader("Quick Queries")
    quick_queries = [
        "What objects were detected near the port?",
        "Summarize activity in the observation zone",
        "What facilities are near NGA headquarters?",
        "Show recent detection alerts",
    ]
    for q in quick_queries:
        if st.button(q, use_container_width=True):
            st.session_state.messages.append({"role": "user", "content": q})
            st.rerun()
