-- Ultimas 24 horas: el filtro usa PAYMENT.updated_at.
WITH es AS (
 SELECT payment_id,SUM(CASE WHEN provider_status='APPROVED' THEN 1 ELSE 0 END) approvals,
 SUM(CASE WHEN provider_status='DECLINED' THEN 1 ELSE 0 END) declines FROM PROVIDER_EVENT GROUP BY payment_id
), ls AS (
 SELECT payment_id,SUM(CASE WHEN entry_type='DEBIT' THEN amount WHEN entry_type='REVERSAL' THEN -amount ELSE 0 END) net_debit,
 SUM(CASE WHEN entry_type='DEBIT' THEN 1 ELSE 0 END) debit_count FROM LEDGER_ENTRY GROUP BY payment_id
)
SELECT p.external_ref,p.status,p.amount expected_amount,NVL(ls.net_debit,0) net_debit,
 NVL(ls.debit_count,0) debit_count,NVL(es.approvals,0) approvals,NVL(es.declines,0) declines
FROM PAYMENT p LEFT JOIN es ON es.payment_id=p.id LEFT JOIN ls ON ls.payment_id=p.id
WHERE p.updated_at>=SYSTIMESTAMP-INTERVAL '24' HOUR
AND ((NVL(es.approvals,0)>0 AND NVL(es.declines,0)>0) OR NVL(es.declines,0)>0
 OR NVL(es.approvals,0)=0 OR NVL(ls.net_debit,0)<>p.amount OR NVL(ls.debit_count,0)>1
 OR (p.status<>'CONFIRMED' AND NVL(ls.net_debit,0)=p.amount))
ORDER BY p.updated_at DESC;

-- Todos los fixtures, sin filtro de fecha.
SELECT p.external_ref,p.status,p.amount expected_amount,
 NVL(SUM(CASE WHEN l.entry_type='DEBIT' THEN l.amount WHEN l.entry_type='REVERSAL' THEN -l.amount ELSE 0 END),0) net_debit,
 SUM(CASE WHEN l.entry_type='DEBIT' THEN 1 ELSE 0 END) debit_count
FROM PAYMENT p LEFT JOIN LEDGER_ENTRY l ON l.payment_id=p.id
GROUP BY p.external_ref,p.status,p.amount ORDER BY p.external_ref;
