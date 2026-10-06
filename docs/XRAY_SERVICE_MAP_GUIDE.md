# X-Ray Service Map 가이드

## 🗺️ 개요

X-Ray Service Map은 마이크로서비스 간 호출 관계와 성능을 시각화합니다.
OTEL Collector가 수집한 트레이스를 기반으로 자동 생성됩니다.

## 🏗️ 아키텍처

```
Application → OTEL SDK → OTEL Collector → X-Ray → Service Map
                ↓
          Auto-instrumentation
```

## 🚀 애플리케이션 계측

### 1. Java Spring Boot

```java
// build.gradle
dependencies {
    implementation 'io.opentelemetry:opentelemetry-api:1.32.0'
    implementation 'io.opentelemetry.instrumentation:opentelemetry-spring-boot-starter:1.32.0'
}

// application.yml
otel:
  exporter:
    otlp:
      endpoint: http://otel-collector.monitoring.svc:4317
  resource:
    attributes:
      service.name: service-order
      service.namespace: nebula
      deployment.environment: ${ENVIRONMENT}
```

### 2. Node.js Express

```javascript
// tracing.js
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { Resource } = require('@opentelemetry/resources');
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');

const sdk = new NodeSDK({
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: 'api-gateway',
    [SemanticResourceAttributes.SERVICE_NAMESPACE]: 'nebula',
    [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: process.env.ENVIRONMENT,
  }),
  traceExporter: new OTLPTraceExporter({
    url: 'http://otel-collector.monitoring.svc:4317',
  }),
});

sdk.start();

// app.js
require('./tracing');  // Must be first import
const express = require('express');
```

### 3. Python FastAPI

```python
# requirements.txt
opentelemetry-api==1.20.0
opentelemetry-sdk==1.20.0
opentelemetry-instrumentation-fastapi==0.41b0
opentelemetry-exporter-otlp==1.20.0

# main.py
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

# Configure tracing
resource = Resource.create({
    "service.name": "user-service",
    "service.namespace": "nebula",
    "deployment.environment": os.environ.get("ENVIRONMENT", "dev")
})

provider = TracerProvider(resource=resource)
processor = BatchSpanProcessor(
    OTLPSpanExporter(endpoint="http://otel-collector.monitoring.svc:4317")
)
provider.add_span_processor(processor)
trace.set_tracer_provider(provider)

# Auto-instrument FastAPI
app = FastAPI()
FastAPIInstrumentor.instrument_app(app)
```

### 4. Go (Gin)

```go
// go.mod
require (
    go.opentelemetry.io/otel v1.19.0
    go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.19.0
    go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin v0.45.0
)

// main.go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
    "go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin"
)

func initTracer() {
    exporter, _ := otlptracegrpc.New(
        context.Background(),
        otlptracegrpc.WithEndpoint("otel-collector.monitoring.svc:4317"),
        otlptracegrpc.WithInsecure(),
    )
    
    resource := resource.NewWithAttributes(
        semconv.SchemaURL,
        semconv.ServiceName("auth-service"),
        semconv.ServiceNamespace("nebula"),
        semconv.DeploymentEnvironment(os.Getenv("ENVIRONMENT")),
    )
    
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(resource),
    )
    
    otel.SetTracerProvider(tp)
}

func main() {
    initTracer()
    
    r := gin.New()
    r.Use(otelgin.Middleware("auth-service"))
    // ... routes
}
```

## 📊 Service Map 기능

### 1. 서비스 의존성 시각화

Service Map에서 확인 가능한 정보:
- **노드**: 각 마이크로서비스
- **엣지**: 서비스 간 호출 관계
- **색상**: 서비스 상태 (녹색=정상, 노란색=경고, 빨간색=오류)
- **숫자**: 평균 응답 시간, 요청 수, 오류율

### 2. 성능 메트릭

각 서비스 노드 클릭 시:
- **Latency Distribution**: P50, P90, P95, P99
- **Request Rate**: 초당 요청 수
- **Error Rate**: 오류 비율
- **Traces**: 해당 서비스의 트레이스 목록

### 3. 트레이스 분석

```bash
# AWS CLI로 트레이스 조회
aws xray get-trace-summaries \
  --time-range-type LastHour \
  --query 'TraceSummaries[?ResponseTime > `3`]'

# 특정 트레이스 상세 조회
aws xray batch-get-traces \
  --trace-ids "1-5f4a3b2c-1234567890abcdef"
```

## 🔍 Service Map 활용

### 1. 병목 지점 찾기

1. Service Map 접속
2. 높은 레이턴시 서비스 식별 (빨간색/노란색 노드)
3. 해당 서비스 클릭 → Traces 확인
4. 느린 스팬(Span) 분석

### 2. 오류 추적

1. Error Rate가 높은 서비스 찾기
2. 서비스 클릭 → "View traces with errors"
3. 오류 트레이스 분석
4. Root cause 파악

### 3. 의존성 분석

1. 특정 서비스의 downstream 서비스 확인
2. 호출 체인 분석
3. 불필요한 호출 최적화

## 📈 X-Ray 그룹 활용

### 생성된 그룹들

| 그룹 | 용도 | 필터 |
|------|------|------|
| **High Latency** | 느린 요청 추적 | `duration > 3` |
| **Errors** | 오류 요청 추적 | `error = true OR fault = true` |
| **Production** | 프로덕션 서비스 | `service("*.production.*")` |
| **각 마이크로서비스** | 서비스별 추적 | `service("서비스명")` |

### 커스텀 그룹 생성

```bash
# CLI로 그룹 생성
aws xray create-group \
  --group-name "Critical-Path" \
  --filter-expression 'service("core-gateway") OR service("service-order")'
```

## 🎯 샘플링 전략

### 환경별 샘플링 비율

| 환경 | 기본 샘플링 | 오류 샘플링 | Critical 서비스 |
|------|------------|------------|----------------|
| **Dev** | 10% | 100% | 50% |
| **Staging** | 5% | 100% | 30% |
| **Production** | 1% | 100% | 10% |

### 동적 샘플링 조정

```bash
# 샘플링 규칙 업데이트
aws xray update-sampling-rule \
  --rule-name "dev-default" \
  --fixed-rate 0.2  # 20%로 증가
```

## 🔧 트러블슈팅

### Service Map이 비어있을 때

1. **OTEL Collector 확인**
```bash
kubectl logs -n monitoring deployment/otel-collector | grep xray
```

2. **애플리케이션 계측 확인**
```bash
# 트레이스가 전송되는지 확인
kubectl logs deployment/api-gateway | grep trace
```

3. **X-Ray 권한 확인**
```bash
aws xray get-service-graph --start-time $(date -u -d '1 hour ago' +%s) --end-time $(date +%s)
```

### 트레이스가 끊어질 때

1. **TraceID 전파 확인**
   - HTTP 헤더: `X-Amzn-Trace-Id`
   - W3C 헤더: `traceparent`

2. **Context Propagation 설정**
```yaml
# OTEL Collector config
processors:
  batch:
    send_batch_size: 50
    timeout: 10s
```

### 성능 이슈

1. **샘플링 비율 조정**
2. **배치 크기 최적화**
3. **메모리 제한 확인**

## 📚 참고 자료

- [AWS X-Ray 문서](https://docs.aws.amazon.com/xray/)
- [OpenTelemetry 계측 가이드](https://opentelemetry.io/docs/instrumentation/)
- [X-Ray Service Map](https://docs.aws.amazon.com/xray/latest/devguide/xray-console-servicemap.html)
