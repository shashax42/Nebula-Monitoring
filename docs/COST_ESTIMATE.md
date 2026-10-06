# 모니터링 비용 산정 (템플릿)

이 문서는 **계산 방법과 측정 쿼리**만 담는다. 숫자는 실제 환경에서 측정한 값과 그 시점의 AWS 요금표로 채운다.
추정치를 근거 없이 적지 않는다 — 이력서·보고서에 비용 수치를 쓸 때는 아래 "측정" 열의 결과와 측정 기간을 함께 남긴다.

요금표: [AMP](https://aws.amazon.com/prometheus/pricing/) · [CloudWatch](https://aws.amazon.com/cloudwatch/pricing/) ·
[X-Ray](https://aws.amazon.com/xray/pricing/) · [AMG](https://aws.amazon.com/grafana/pricing/) · [S3](https://aws.amazon.com/s3/pricing/) ·
[Firehose](https://aws.amazon.com/firehose/pricing/) (리전: ap-northeast-2)

---

## 1. 입력값 — 측정 방법

측정은 평상시 트래픽에서 최소 7일 평균을 쓴다 (`[7d]`). 로컬 스택/시뮬레이터 값은 비용 근거로 쓰지 않는다.

| # | 입력 | 단위 | 측정 (AMP / CloudWatch) | 측정값 | 측정 기간 |
|---|---|---|---|---|---|
| A | AMP 수집 샘플 | 샘플/s | `sum(rate(otelcol_exporter_sent_metric_points_total{exporter=~"prometheus_remote_write.*"}[7d]))` | | |
| B | AMP 활성 시리즈 | 개 | AMP 콘솔 Workspace → Active series (또는 `count({__name__=~".+"})`) | | |
| C | AMP 쿼리 처리량 | QSP/월 | CloudWatch `AWS/Prometheus` `QuerySamplesProcessed` (규칙 평가 + 대시보드 + 카나리 분석) | | |
| D | CloudWatch Logs 수집량 | GB/일 | CloudWatch `AWS/Logs IncomingBytes` (로그 그룹 `/aws/eks/<cluster>/*` 합계) | | |
| E | 로그 보존 저장량 | GB | 로그 그룹별 `StoredBytes` | | |
| F | EMF 커스텀 메트릭 수 | 개 | `Nebula/Application` 네임스페이스 메트릭×차원 조합 수 (기본: SLI 3종 × (서비스 수 + 1)) | | |
| G | CloudWatch 알람 수 | 개 | `terraform state list \| grep metric_alarm \| wc -l` (+ composite) | | |
| H | X-Ray 기록 트레이스 | 트레이스/월 | `sum(increase(otelcol_exporter_sent_spans_total{exporter="awsxray"}[30d]))` ÷ 평균 스팬 수/트레이스 | | |
| I | X-Ray 조회 트레이스 | 트레이스/월 | X-Ray 콘솔 사용량 (대부분 장애 분석 시) | | |
| J | AMG 사용자 | 명 (Editor/Viewer) | AMG 워크스페이스 사용자 목록 | | |
| K | S3 아카이브 유입 | GB/월 | Firehose `DeliveryToS3.Bytes` | | |
| L | 정제로 줄인 양 | % | `Nebula / Telemetry Pipeline` 대시보드 "정제로 제거된 양" | | |

## 2. 계산식

단가는 요금표에서 옮겨 적는다 (`P_*`). 티어 구간 요금은 첫 구간만 쓰지 말고 실제 사용량 구간을 적용한다.

| 항목 | 식 | 단가 (기준일) | 월 비용 |
|---|---|---|---|
| AMP 수집 | A × 2,592,000 (초/30일) ÷ 10⁶ × `P_ingest(백만 샘플)` | | |
| AMP 저장 | 샘플 크기 × A × 보존 일수 → GB × `P_storage(GB-월)` | | |
| AMP 쿼리 | C ÷ 10⁹ × `P_query(10억 QSP)` | | |
| CloudWatch Logs 수집 | D × 30 × `P_logs_ingest(GB)` | | |
| CloudWatch Logs 저장 | E × `P_logs_storage(GB-월)` | | |
| EMF 커스텀 메트릭 | F × `P_metric(메트릭-월)` (+ EMF 로그 수집분은 D 에 포함) | | |
| 알람 | G × `P_alarm` (고해상도·복합 알람 단가 별도) | | |
| X-Ray | (H − 무료 구간) ÷ 10⁶ × `P_trace_record` + I ÷ 10⁶ × `P_trace_retrieve` | | |
| AMG | Editor × `P_editor` + Viewer × `P_viewer` | | |
| S3 + Firehose | K × `P_firehose(GB)` + 계층별(IA → Glacier IR → Deep Archive) 저장 단가 | | |
| **합계** | | | |

## 3. 비용 레버 — 어디를 바꾸면 얼마나 줄어드나

| 레버 | 설정 위치 | 영향을 주는 입력 |
|---|---|---|
| tail sampling baseline 비율 | `pipeline.traces.baselineSamplingPercent` (env 별 values) | H |
| 로그 최소 레벨, 노이즈 필터 | `pipeline.logs.minSeverityNumber`, agent `filter/logs-noise` | D, E |
| 로그 Hot 보존 | `terraform` `log_retention_days`, `audit_log_hot_retention_days` | E |
| scrape 허용 목록 / KSM allowlist | agent `metric_relabel_configs`, `helm/kube-state-metrics/values.yaml` | A, B |
| span metrics 차원 | gateway `span_metrics.dimensions` (차원 1개 추가 = 시리즈 × 값 개수) | A, B |
| EMF 서비스 목록 | gateway `metric_declarations`, `slo_services` | F, G |
| 확장 구성 | `values-extension-business.yaml`, `enable_business_extensions` | A, B, F, G |
| 규칙 평가 주기 | `prometheus/rules/*` `interval` | C |

## 4. 기록

| 측정일 | 환경 | 합계(월) | 비고 (트래픽 규모, 변경 사항) |
|---|---|---|---|
| | | | |
