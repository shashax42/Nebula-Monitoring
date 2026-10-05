# Local stack — 클러스터/AWS 없이 파이프라인 전체를 확인

```
simulate.py ──OTLP──► agent ──► gateway ──► Prometheus (prometheus/rules/*.yaml 그대로 평가)
                 (sample-logs 도 file_log 로 수집)       └──► Grafana (grafana/dashboards/*.json 그대로)
                                     └──► ./out/*.json (X-Ray / EMF / CloudWatch Logs 로 갈 데이터)
```

`render.py` 는 `helm/otel-collector/values.yaml` 의 설정을 그대로 쓰고 **AWS exporter 만** 로컬 대체물로 바꾼다
(k8s API 가 필요한 k8sattributes·kubelet scrape 는 제외). 그래서 여기서 본 정제/가공 결과 = 클러스터에서의 결과다.

```bash
python3 render.py
docker compose up -d
python3 ../telemetry-simulator/simulate.py --endpoint http://localhost:4318            # 평상시
python3 ../telemetry-simulator/simulate.py --endpoint http://localhost:4318 --scenario pg-timeout
```

| 확인할 것 | 어디서 |
|---|---|
| 대시보드 | http://localhost:3000 (admin/admin) → Nebula 폴더 |
| 레코딩 규칙 값 / 알림 | http://localhost:9090/rules, /alerts |
| PII 마스킹·로그 구조화 결과 | `out/logs-application.json`, `out/logs-audit.json` |
| tail sampling 후 남은 트레이스 | `out/xray-traces.json` |
| CloudWatch 로 갈 SLI/결제 메트릭(EMF) | `out/cloudwatch-emf.json` |

시나리오: `pg-timeout`(PG 타임아웃 급증) · `noisy`(한 테넌트 DB 독점) · `deficit`(쿠폰 남발 역마진) · `bot`(장바구니 점유).
5분/1시간 창 규칙은 그만큼 데이터가 쌓여야 값이 나온다. 정리: `docker compose down -v`.
