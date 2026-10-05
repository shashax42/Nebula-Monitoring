# Nebula Runbook

알림의 `runbook_url` 이 가리키는 문서. 각 항목은 **의미 → 먼저 볼 것 → 조치** 순서다.
모든 알림은 심각도별 SNS 토픽(`<env>-alerts-critical` / `<env>-alerts-warning`)으로 온다.

| 심각도 | 의미 | 기대 대응 |
|---|---|---|
| `critical` | 고객 영향이 있거나 곧 생긴다 (SLA·결제·파이프라인 단절) | 즉시 |
| `warning` | 버짓을 소진 중이거나 용량/품질이 나빠지는 중 | 업무 시간 내 |
| `info` | 효율/이상 징후 참고 (하루 1회 묶음) | 주간 리뷰 |

공통 도구
- Grafana: `Nebula / Overview (Q1–Q5)` → 서비스면 `Service SLO`, 결제면 `Business Flow & Payments`, 테넌트면 `Tenants`
- 로그: CloudWatch Logs Insights 저장 쿼리 `nebula-<env>/*` (trace_id 로 로그 ↔ 트레이스 이동)
- 트레이스: X-Ray (인덱스 속성 `http.route`, `tenant.id`, `payment.outcome`)

---

## SLA Availability
CloudWatch `<env>-sla-availability[-<service>]`. EMF 메트릭 `Nebula/Application Requests/Errors` 로 계산한 가용성이 SLA(99.9%) 미만.
- 먼저: `Service SLO` 대시보드 → 에러율/라우트 표 → 에러 로그 패널의 trace_id 로 X-Ray.
- 조치: 최근 배포가 있으면 롤백(Argo Rollouts 분석 결과 확인). 의존성 문제면 `ServiceDependencyErrorsHigh` 참고.

## SLOAvailabilityBurn
`SLOAvailabilityBurnFast/Slow`. 30일 에러 버짓(0.1%)을 정상 속도의 N배로 소진 중. `window` 라벨이 판단 창.
- 14.4x(1h): 1시간에 버짓 2% 소진 → 지금 장애. 6x(6h): 지속적 저하.
- 먼저: `Time to Burn Out` 패널(남은 시간), 라우트별 에러, `service_edge` 의존성 표.
- 조치: 원인 라우트 격리/롤백. 버짓이 바닥나면 기능 배포를 멈추고 안정화 작업 우선.

## SLOLatencyBurn
지연 SLO(P95 < 1s ⇔ 1s 초과 요청 5% 미만) 버짓 소진. CloudWatch `<env>-latency-slo` 도 같은 SLI.
- 먼저: P99 라우트 표, `ContainerCPUThrottlingHigh`, DB(`Data Stores`) 락/CPU, Redis evictions.
- 조치: 스로틀링이면 CPU limit 상향, DB 면 쿼리/인덱스, 캐시 축출이면 Redis 용량.

## ServiceDependencyErrorsHigh
service_graph 기준 client → server 호출 실패율 5% 초과.
- 먼저: X-Ray 서비스 맵에서 해당 edge, 피호출 서비스의 SLO 대시보드.
- 조치: 피호출 서비스 장애 대응, 호출 측 타임아웃/서킷브레이커 확인.

## TenantEnterpriseSLOBurn
Enterprise 티어 테넌트의 에러율이 SLA(99.95%) 버짓을 급속 소진 → 계약 위반 위험.
- 먼저: `Tenants` 대시보드에서 해당 tenant_id 의 서비스별 트래픽, X-Ray 에서 `annotation.tenant_id` / `tenant.id` 필터.
- 조치: 고객 공지 여부 판단(CS/영업 공유), 원인 서비스 대응.

## TenantNoisyNeighbor
한 테넌트가 DB 처리시간의 50% 이상 점유 (테넌트 3개 이상 공유 시).
- 판별: `DB 호출 수`가 함께 급증 → **트래픽 문제**(레이트 리밋/큐잉). 호출 수는 평소, `DB 쿼리 P99`만 상승 → **데이터셋/쿼리 문제**(인덱스·파티셔닝·대용량 테넌트 분리).
- 함께: Aurora `RowLockTime`, `Deadlocks`, `BlockedTransactions`.

## PaymentSystemFailureHigh
PG 별 시스템 원인(pg_timeout / pg_unavailable / other) 실패율 2% 초과. CloudWatch `<env>-payment-pg-timeout` 도 같은 계열.
- 먼저: `실패 원인별 결제 실패` 패널(색: 주황/빨강 = 시스템, 파랑 = 고객), PG 응답 P99.
- 조치: 해당 PG 우선순위 낮추기(대체 PG 라우팅), PG 사 장애 공지 확인. `other` 가 많으면 PG 코드표로 분류 규칙 보강(docs/TELEMETRY_CONTRACT.md 5장).

## PaymentDeclineSpike
특정 결제수단/카드사의 승인 거절률이 평소(1일 평균)의 2배 이상 + 5% 초과.
- 의미: 카드사 정책 변경, 특정 커뮤니티 유입 급증 등 **외부 요인**. 우리 시스템 장애가 아닐 수 있다.
- 조치: 결제수단 노출 순서 조정, 프로모션 대상 카드사 확인.

## PaymentLogicalErrors
HTTP 2xx 인데 `payment.outcome=failure` 인 결제 (조용한 실패). HTTP 지표/가용성 SLO 로는 보이지 않는다.
- 먼저: X-Ray 에서 `payment.outcome = "failure"` 트레이스 (tail sampling 이 100% 보존), 감사 로그 저장 쿼리 `05-payment-audit-trail`.
- 조치: PG 응답 파싱/상태 동기화 로직 점검, 영향 주문 대사(정산 팀 공유).

## CheckoutConversionDrop
퍼널 단계 전환율이 평소의 절반 미만 (장바구니 1시간 100건 이상일 때).
- 먼저: 어느 `step` 인지 → 해당 단계 서비스의 에러/지연, 최근 배포/프로모션.

## CartHoardingSuspected
장바구니 담기 / 결제 시작 비율이 평소의 2배 이상 → 결제 없이 재고만 점유하는 봇 의심.
- 조치: WAF/봇 탐지 로그 대조, 결제 미진행 장바구니 예약 재고의 TTL 단축. (세션 단위 Think Time 분석은 Phase 3)

## AsyncBacklogGrowing
Kafka consumer lag / RabbitMQ ready 메시지가 1000 이상이고 증가 중. `AsyncLagWhileAPIHealthy` 는 API 에러율이 정상(1% 미만)인데 lag 이 계속 쌓이는 경우(critical) — 주문/결제 후처리 지연.
- 조치: 컨슈머 스케일아웃, 처리 실패/재시도 루프(데드레터) 확인, 다운스트림(DB) 포화 여부.

## NetMarginDeficit
`NetMarginLow`(5% 미만), `NetMarginDeficit`(0% 미만), `MarginDeficitPredicted`(6시간 내 적자 전환 예측).
- 먼저: `FinOps & Margin` → 비용 구성(쿠폰/배송비/PG 수수료) 중 급증 항목, 결제수단 비중.
- 조치: 프로모션 쿠폰 발급 제한(서킷 브레이커), 저수수료 결제수단 상단 노출. 인프라 단가는 `prometheus/rules/05-finops.rules.yaml` 상수.

## TrafficAnomaly
요청률 z-score |z| > 3 (최근 1일 대비). info — 급증은 외부 유입/봇, 급감은 상위 장애/라우팅 문제 가능성.

## ErrorRatioAnomaly
에러율 z-score > 3 이고 1% 초과. 배포 직후라면 롤백 판단 근거 (`k8s/argo-rollouts/analysis-template.yaml` 과 같은 지표).

## ErrorLogSpike
서비스 ERROR/FATAL 로그 z-score > 3. 저장 쿼리 `02-top-error-messages` 로 새로 생긴 에러 시그니처 확인.

## IdleResourceHigh
네임스페이스 requests 대비 1일 평균 사용률이 20% 미만 (유휴 점수 > 0.8). 다운사이징 후보 — `Overview` Q4 표에서 파드 단위 확인.

## KubeNodeNotReady
노드 Ready=false 5분 이상. `kubectl describe node`, EC2 상태 검사, kubelet 로그. ASG 가 교체하지 않으면 수동 cordon/drain.

## KubeNodePressure
Memory/Disk/PID Pressure. DiskPressure 면 이미지/로그 정리(EBS 확장), MemoryPressure 면 requests 미설정 파드 확인.

## NodeCPUHigh
노드 CPU 80% 이상 15분. Karpenter/Cluster Autoscaler 동작 확인, requests 와 실제 사용량 괴리 점검.

## NodeMemoryHigh
노드 메모리 85% 이상 15분. 메모리 limit 없는 파드, 누수 확인.

## KubePodCrashLooping
CrashLoopBackOff / 15분 3회 이상 재시작. `kubectl logs --previous`, 최근 설정/시크릿 변경, 의존성(DB) 연결.

## KubeContainerOOMKilled
OOMKilled 재시작. `ContainerMemoryNearLimit` 선행 여부 확인 → limit 상향 또는 메모리 누수 수정.

## KubePodNotHealthy
Pending/Unknown/Failed 15분 이상. Pending 이면 이벤트 로그(`06-k8s-warning-events` 쿼리)에서 FailedScheduling 사유.

## KubeDeploymentReplicasMismatch
가용 replica 부족 15분. 롤아웃 정체(이미지 pull, readiness 실패) 또는 용량 부족.

## KubeJobFailed
Job 실패. `kubectl logs job/<name>`, 재시도 정책.

## KubePersistentVolumeFillingUp
PVC 여유 10% 미만. 볼륨 확장(EBS online resize) 또는 데이터 정리.

## ContainerCPUThrottlingHigh
CFS 스로틀링 25% 이상 — P99 악화의 숨은 원인. CPU limit 상향 또는 제거(requests 만 유지) 검토.

## TelemetryGatewayAbsent
gateway 자체 메트릭이 AMP 에 5분 이상 없음 → 메트릭/트레이스/로그 전송 전체 중단 가능성. CloudWatch `telemetry-log-ingestion-stopped` 가 함께 울리면 확정.
- 확인: `kubectl -n monitoring get pods -l app.kubernetes.io/component=gateway`, gateway 로그의 `AccessDenied`(IRSA trust/정책), AMP 엔드포인트.
- 이 알림이 떠 있는 동안 `TelemetryAgentMissing`/`ScrapeTargetDown` 은 억제된다.

## TelemetryAgentMissing
노드 수 > 동작 중인 agent 수. 해당 노드의 로그/kubelet 메트릭 유실. DaemonSet 이벤트(taint, 리소스 부족, hostPath 권한).

## ScrapeTargetDown
scrape 실패 10분. 타겟 파드 상태, NetworkPolicy, `prometheus.io/port` 어노테이션 확인.

## CollectorExportFailing
exporter 전송 실패 지속 (`signal` 라벨). AWS 권한, 스로틀링(CloudWatch PutLogEvents / AMP 수집 한도), 네트워크. 큐가 차면 데이터 유실 — `CollectorQueueNearFull` 함께 확인.

## CollectorRefusingData
memory_limiter 가 데이터를 거부(백프레셔). gateway HPA 상한/메모리 limit 상향, 또는 agent 단계 필터 강화(로그 최소 레벨 상향 등).

## TailSamplingDroppingTraces
결정 전에 트레이스가 버려짐 — `tail_sampling.num_traces` 가 (초당 신규 트레이스 × decision_wait) 보다 작다. 값 상향 또는 gateway replica 증설.

## HighCardinalityTarget
한 scrape 타겟이 2만 샘플 이상. 해당 job 의 `metric_relabel_configs` 허용 목록/labeldrop 추가 (values.yaml agent prometheus 설정).
