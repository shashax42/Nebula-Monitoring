# Local stack — 클러스터/AWS 없이 파이프라인 전체를 확인

```
simulate.py ──OTLP──► agent ──► gateway ──► Prometheus (prometheus/rules/*.yaml 그대로 평가)
   └ pod-logs/ (CRI 로그) ──┘ file_log          └──► Grafana (grafana/dashboards/*.json 그대로)
                                     └──► ./out/*.json (X-Ray / EMF / CloudWatch Logs 로 갈 데이터)
```

`render.py` 는 `helm/otel-collector/values.yaml` 의 설정을 그대로 쓰고 **AWS exporter 만** 로컬 대체물로 바꾼다
(k8s API 가 필요한 k8sattributes·kubelet scrape 는 제외 — 시뮬레이터가 `deployment.track` 등 리소스 속성을 직접 붙인다).
그래서 여기서 본 정제/가공 결과 = 클러스터에서의 결과다.

```bash
python3 render.py                 # 기본 배포 구성  (--extensions: 테넌트·결제·마진 오버레이·규칙·대시보드 포함)
docker compose up -d
python3 ../telemetry-simulator/simulate.py                          # 평상시
python3 ../telemetry-simulator/simulate.py --scenario canary-bad    # 카나리 판정 (아래 쿼리)
```

| 시나리오 | 무엇이 일어나나 | 확인 |
|---|---|---|
| `normal` | 주문·조회 트래픽, 재고 부족 거절 ~2% | 알림 없음 |
| `canary-bad` | service-order canary 파드가 6% 를 500 으로 응답 (스팬 상태 UNSET — Micrometer 동작) | gateway 가 ERROR 로 판정 → 분석 쿼리 실패(롤백), `Service SLO` 의 canary vs stable 패널 |
| `kafka-down` | purchase 발행 20% 실패 | `SagaPublishFailures` (약 10분) |
| `consumer-stall` | service-product 가 purchase 를 처리하지 않음, lag 증가 | `SagaStalled`, `AsyncBacklogGrowing` |
| `compensation-gap` | 재고 거절 후 주문 취소 70% 누락 | `SagaCompensationGap` (약 30분) |
| `stock-out` | 재고 부족 거절 30% | `StockRejectionSpike` — 1일 기준선 필요, 짧게 돌리면 발화하지 않는 것이 정상 |
| `--extensions` + `pg-timeout` · `noisy` · `deficit` · `bot` | 확장 계약 데이터 | `render.py --extensions` 로 띄운 경우만 |

카나리 분석 쿼리 확인 (nebula-gitops `platform/aws/base/analysis-slo-canary.yaml` 과 같은 식):
```bash
curl -s localhost:9090/api/v1/query --data-urlencode 'query=
  sum(rate(traces_span_metrics_calls_total{service_name="service-order",deployment_track="canary",span_kind="SPAN_KIND_SERVER",status_code="STATUS_CODE_ERROR"}[2m]))
  / sum(rate(traces_span_metrics_calls_total{service_name="service-order",deployment_track="canary",span_kind="SPAN_KIND_SERVER"}[2m]))'
```

| 확인할 것 | 어디서 |
|---|---|
| 대시보드 | http://localhost:3000 (admin/admin) → Nebula 폴더 |
| 레코딩 규칙 값 / 알림 | http://localhost:9090/rules, /alerts |
| Micrometer → 표준 속성, actuator 제거 | Prometheus 에서 `traces_span_metrics_calls_total` 의 `http_route`, `deployment_track`, `messaging_destination_name` |
| PII 마스킹·Spring 로그 구조화 결과 | `out/logs-application.json` |
| tail sampling 후 남은 트레이스 (주문 → Kafka → 재고 → 취소 한 트레이스) | `out/xray-traces.json` |
| CloudWatch 로 갈 SLI 메트릭(EMF) | `out/cloudwatch-emf.json` |

5분/1시간 창 규칙은 그만큼 데이터가 쌓여야 값이 나온다. 정리: `docker compose down -v && rm -rf pod-logs out generated`.
