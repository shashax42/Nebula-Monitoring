# ADR 0001 — 기본 텔레메트리는 실제 서비스 기준, 테넌트·결제·마진은 확장으로 분리

- 상태: 채택
- 관련: nebula-services (Micrometer → OTLP, 사가 카운터), nebula-gitops (service-order canary 분석), Nebula-Platform

## 배경

첫 구현은 설계 문서(Phase 2 Observability)의 목표 아키텍처를 그대로 옮겼다. 멀티테넌시(`tenant.id` 라벨링, Noisy Neighbor),
결제 PG 실패 코드 분류·논리 오류, 매출 대비 마진(역마진)까지 기본 배포에 들어 있었다.

nebula-services 를 확인한 결과는 달랐다.

| 설계가 가정한 것 | 실제 서비스 |
|---|---|
| `x-tenant-id`, Baggage `tenant.id` | 테넌트 개념 없음 |
| 결제 서비스, PG 연동, `payment.*` 스팬·메트릭 | 결제 서비스 없음 |
| 장바구니 → 결제 퍼널 이벤트, 매출·원가 이벤트 | 없음 |
| OTel SDK 표준 속성 (`http.route` 등) | Micrometer Observation 속성 (`uri`, `method`, `status`), 예외 없는 5xx 는 스팬 상태 UNSET |
| — | **주문 사가**: service-order → Kafka `purchase` → service-product → (재고 부족 시) `refund` → 주문 취소 |

데이터가 들어오지 않는 지표를 기본으로 두면 다음 비용이 생긴다.

1. **알림·대시보드의 신뢰도**: 항상 비어 있는 패널과 절대 울리지 않는 알림이 섞이면, 진짜 신호도 무시하게 된다.
2. **검증 불가**: 시뮬레이터로만 값이 나오는 지표는 "동작한다"고 말할 근거가 없다.
3. **비용**: CloudWatch 커스텀 메트릭(결제 차원 조합), 추가 커넥터·처리기의 CPU, 규칙 평가 비용.
4. **실제 위험의 누락**: 서비스에 있는 위험(Kafka 발행 실패, 보상 트랜잭션 누락, 배포 결함)은 감시하지 않고 있었다.

## 결정

**기본 배포 = 지금 서비스가 내보내는 데이터.** 없는 기능의 지표는 지우지 않고 **확장**으로 옮긴다 (기능이 생기면 계약대로 켠다).

| 구분 | 기본 (core) | 확장 (extension, 기본 off) |
|---|---|---|
| collector | Micrometer → OTel 표준 변환(+5xx=ERROR), span metrics 에 `messaging.destination.name`·`deployment.track`, service_graph, 로그 정제 | `values-extension-business.yaml`: 테넌트 라벨링·테넌트 RED, 결제 논리 오류 카운트, PG 코드 분류, 결제 로그 라우팅, 결제 EMF |
| 규칙 | `04-business` 주문 사가(발행 실패·사가 정지·보상 누락·재고 거절·완료율) + Kafka, `05-cost` 인프라 비용 | `extensions/tenant`, `extensions/commerce-payment`, `extensions/margin` |
| 알림 | SLA·번레이트·사가·Kafka·데이터스토어·파이프라인 | 결제 CloudWatch 알람, 테넌트 SLA, 역마진 |
| 대시보드 | Overview, Service SLO(+canary vs stable), Order Saga, Infra Cost, Data Stores, Pipeline | Ext / Funnel & Payments, Tenants, Margin |
| 배포 게이트 | service-order Argo Rollouts canary + AMP 분석 (`nebula-slo-canary`) | — |

켜는 방법: `-f values-extension-business.yaml`, `terraform -var enable_business_extensions=true`, `provision-grafana.sh <env> --extensions`.
확장 규칙은 기본 규칙과 함께 로드하는 단위 테스트(`prometheus/tests/extensions.test.yaml`)로 이름 충돌과 의존 관계를 계속 검증한다.

## 새로 추가한 것과 이유

| 추가 | 이유 |
|---|---|
| `transform/micrometer-semconv` | 계측 라이브러리와 무관하게 하나의 계약(OTel semconv)으로 규칙·대시보드를 유지. 5xx 를 ERROR 로 판정하지 않으면 가용성 SLI 가 `@ControllerAdvice` 로 처리된 장애를 놓친다 |
| 사가 단계 카운터 + 규칙 | HTTP 200 뒤에서 깨지는 흐름(발행 실패, 컨슈머 정지, 보상 누락)은 Golden Signals 로 보이지 않는다. 보상 누락은 데이터 정합성 문제라 critical |
| Kafka observation 활성화 | 커스텀 KafkaTemplate/listener factory 는 `spring.kafka.*` 자동설정을 받지 않아 트레이스가 토픽에서 끊겼다 |
| canary/stable 라벨 → span metrics → AMP 분석 | 배포 결함과 외부 장애를 구분하려면 같은 시점의 stable 과 비교해야 한다 (상대 기준). 별도 계측 없이 span metrics 차원 하나로 해결 |
| 재고 거절은 warning, SLO 와 분리 | 품절은 시스템 장애가 아니다. 같은 채널로 울리면 SLO 알림의 신뢰도가 떨어진다 |

## 결과

- 기본 배포의 모든 알림·패널은 실제 서비스 데이터(또는 서비스와 같은 모양의 시뮬레이터)로 값이 나온다.
- CloudWatch 커스텀 메트릭은 SLI 3종 × (서비스 수 + 1) 로 고정된다.
- 설계 문서의 Phase 2 목표(테넌트·결제·마진)는 계약(TELEMETRY_CONTRACT 7장)과 확장 구성으로 남아, 기능이 생기면 코드 변경 없이 켤 수 있다.
- 트레이드오프: 확장 구성은 실제 데이터로 검증되지 않았다 (단위 테스트와 시뮬레이터 수준). 켤 때 실제 데이터로 임계값을 다시 잡아야 한다.
