# Security — GEOINT Demo

## Dependency Vulnerability Scan

All Python package dependencies for the Demo 0 IoT Backbone components were scanned against the GitHub Advisory Database on **2026-03-03**.

### demo0-iot-backbone/sensor-simulator

| Package | Version | CVEs |
|---------|---------|------|
| paho-mqtt | 1.6.1 | None found |
| asyncio-mqtt | 0.16.2 | None found |

### demo0-iot-backbone/event-triggers/alert-processor

| Package | Version | CVEs |
|---------|---------|------|
| fastapi | 0.110.0 | None found |
| uvicorn[standard] | 0.29.0 | None found |
| httpx | 0.27.0 | None found |
| pydantic | 2.6.4 | None found |
| python-json-logger | 2.0.7 | None found |

**Result: No known CVEs found in any dependency at the scanned versions.**

---

## Design-Level Security Findings

The following findings reflect intentional demo trade-offs and should be addressed before any production or field deployment.

### [DEMO-SEC-001] Plain-text MQTT on port 31883 (NodePort)

**Severity:** Medium  
**Location:** `demo0-iot-backbone/iot-operations/mqtt-broker/broker.yaml` — `geoint-listener-nodeport`  
**Description:** The MQTT broker exposes a non-TLS listener on NodePort 31883 to allow easy demo access from the booth network. Sensor telemetry and credentials are transmitted in plain text on this port.  
**Accepted for Demo:** Yes — TLS listener on port 8883 is available intra-cluster for production use.  
**Remediation before production:** Remove the NodePort listener and route all external MQTT traffic through the TLS ClusterIP listener behind an appropriate load balancer or ingress.

### [DEMO-SEC-002] No authentication on alert-processor HTTP endpoint (intra-cluster)

**Severity:** Low  
**Location:** `demo0-iot-backbone/iot-operations/data-pipelines/pipeline-alerts.yaml` — `authentication: type: None`  
**Description:** The `pipeline-alerts` DataFlow posts to the alert-processor service without any authentication token. This is intentional for a demo environment where both components share the same K8s namespace and rely on network policy for isolation.  
**Accepted for Demo:** Yes.  
**Remediation before production:** Add a shared secret or mTLS between the AIO DataFlow and the alert-processor. Consider using Azure Workload Identity.

### [DEMO-SEC-003] Alert processor in-memory ring buffer only

**Severity:** Informational  
**Location:** `demo0-iot-backbone/event-triggers/alert-processor/processor.py` — `_alert_buffer`  
**Description:** Alerts are stored in a 50-item in-memory `deque`. All historical alerts are lost on pod restart. There is no persistent storage or audit log.  
**Accepted for Demo:** Yes — the demo only requires near-real-time alert visibility.  
**Remediation before production:** Persist alerts to a database (e.g., PostGIS or Azure Data Explorer) and add structured audit logging.

### [DEMO-SEC-004] MQTT credentials stored in K8s Secret (base64, not encrypted at rest)

**Severity:** Low  
**Location:** `demo0-iot-backbone/infra/deploy-iot-backbone.ps1` — `Deploy-Secrets` function  
**Description:** MQTT username/password are stored as a Kubernetes `Secret` object. By default, K8s Secrets are base64-encoded but not encrypted at rest unless etcd encryption is explicitly configured.  
**Accepted for Demo:** Yes — the `.env` file is not committed to source control (see `.gitignore`).  
**Remediation before production:** Enable etcd encryption-at-rest on the AKS cluster, or use Azure Key Vault with the Secrets Store CSI driver to inject credentials directly into pods.

### [DEMO-SEC-005] arc-event-rule.json contains AKS worker IP placeholder in webhook URL

**Severity:** Informational  
**Location:** `demo0-iot-backbone/event-triggers/arc-event-rule.json`  
**Description:** The EventGrid subscription template uses `http://` (not `https://`) for the webhook endpoint URL. If deployed with a real IP and no TLS, event payloads will transit unencrypted.  
**Accepted for Demo:** Yes — the file is a template; the `_comment` field instructs operators to substitute values before applying.  
**Remediation before production:** Expose the alert-processor behind an HTTPS ingress and update the webhook URL to use `https://`.

---

## Reporting New Vulnerabilities

To report a security vulnerability found in this repository, please open a GitHub Issue with the label `security` and include:
- Affected component and file path
- Description of the vulnerability
- Potential impact
- Suggested remediation (if known)
