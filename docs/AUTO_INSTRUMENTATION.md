# OpenTelemetry Auto-Instrumentation 가이드

##OTEL Operator 설치

```bash
# Cert Manager 설치 (OTEL Operator 필수 의존성)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# OTEL Operator 설치
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```

## 언어별 Auto-Instrumentation

### Java 애플리케이션

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-java-app
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-java: "true"
    spec:
      containers:
      - name: app
        image: your-java-app:latest
        env:
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://otel-collector.monitoring.svc:4317"
        - name: OTEL_SERVICE_NAME
          value: "sample-java-app"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "service.namespace=production,service.version=1.0.0"
```

### Python 애플리케이션

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-python-app
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-python: "true"
    spec:
      containers:
      - name: app
        image: your-python-app:latest
        env:
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://otel-collector.monitoring.svc:4317"
        - name: OTEL_SERVICE_NAME
          value: "sample-python-app"
```

### Node.js 애플리케이션

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-nodejs-app
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-nodejs: "true"
    spec:
      containers:
      - name: app
        image: your-nodejs-app:latest
        env:
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://otel-collector.monitoring.svc:4317"
        - name: OTEL_SERVICE_NAME
          value: "sample-nodejs-app"
```

## Context Propagation 

### W3C TraceContext 헤더 자동 전파

Auto-instrumentation이 활성화되면 자동으로 처리됩니다:

```http
# 자동으로 추가되는 헤더
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
tracestate: congo=t61rcWkgMzE
```

### 수동 계측이 필요한 경우

```java
// Java 예시
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Tracer;

Tracer tracer = GlobalOpenTelemetry.getTracer("my-service", "1.0.0");
Span span = tracer.spanBuilder("custom-operation")
    .setSpanKind(SpanKind.INTERNAL)
    .startSpan();
    
try (Scope scope = span.makeCurrent()) {
    // 비즈니스 로직
} finally {
    span.end();
}
```

```python
# Python 예시
from opentelemetry import trace

tracer = trace.get_tracer("my-service", "1.0.0")

with tracer.start_as_current_span("custom-operation") as span:
    # 비즈니스 로직
    span.set_attribute("custom.attribute", "value")
```

## 메트릭 수집 (Prometheus 형식)

애플리케이션에서 Prometheus 메트릭 노출:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: sample-app
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"
spec:
  selector:
    app: sample-app
  ports:
  - port: 8080
    name: metrics
```

##  검증 방법

### 1. Trace 확인
```bash
# OTEL Collector 로그에서 trace 수신 확인
kubectl logs -n monitoring deployment/otel-collector | grep trace

# X-Ray에서 Service Map 확인
aws xray get-service-graph --start-time $(date -u -d '5 minutes ago' +%s) --end-time $(date +%s)
```

### 2. Metrics 확인
```bash
# AMP에 메트릭이 들어오는지 확인
aws amp query-metrics \
  --workspace-id <workspace-id> \
  --query 'up{job="kubernetes-pods"}'
```

### 3. Logs 확인
```bash
# CloudWatch Logs에서 확인
aws logs tail /aws/eks/nebula-eks-dev/otel-collector --follow
```

## Best Practices

1. **Resource Attributes 표준화**
   - `service.name`: 필수
   - `service.namespace`: 환경 구분
   - `service.version`: 버전 관리

2. **Sampling 전략**
   - Dev: 100% (모든 trace)
   - Staging: 50%
   - Production: 10% (또는 adaptive sampling)

3. **Error Tracking**
   - Exception은 자동으로 span event로 기록됨
   - Custom error는 span.record_exception() 사용

4. **Performance 최적화**
   - Batch 처리 활용
   - 불필요한 attribute 제거
   - High-cardinality 데이터 주의

## 참고 자료

- [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator)
- [Auto-instrumentation 상세 가이드](https://opentelemetry.io/docs/kubernetes/operator/automatic/)
- [W3C TraceContext](https://www.w3.org/TR/trace-context/)
