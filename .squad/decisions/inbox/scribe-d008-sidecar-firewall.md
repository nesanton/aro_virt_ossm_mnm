### 2026-04-08: D-008 — virt-launcher iptables overwrite sidecar init rules
**By:** Squad Coordinator
**What:** Sidecar injection successfully injects istio-proxy into virt-launcher pod. istiod connectivity and cert issuance work. However, port 15021 (istio-proxy health check) is connection-refused despite being bound in /proc/net/tcp. Hypothesis: KubeVirt masquerade networking setup in compute container runs AFTER istio-validation init container and overwrites or conflicts with Envoy iptables rules, OR adds DROP/REJECT rules blocking access to istio-proxy ports.
**Evidence:** /proc/net/tcp shows 0.0.0.0:15021 LISTEN. Envoy logs show "Readiness succeeded" and "Envoy proxy is ready". External probe from kubelet: connection refused. curl from compute container to 127.0.0.1:15021: connection refused. cloudInitSecret was missing between pod restarts — restored.
**Resolution pending:** Naomi to investigate virt-launcher iptables rules during pod startup.
