package com.carlos.conciliacion.service;
import com.carlos.conciliacion.dto.*;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.sql.CallableStatement;
import java.sql.Types;
import java.util.List;
@Service
public class ConciliacionService {
    private final JdbcTemplate jdbcTemplate;
    public ConciliacionService(JdbcTemplate jdbcTemplate) { this.jdbcTemplate = jdbcTemplate; }

    @Transactional
    public ConciliacionResponse reconcile(String externalRef) {
        return jdbcTemplate.execute((ConnectionCallback<ConciliacionResponse>) connection -> {
            try (CallableStatement call = connection.prepareCall("{ call RECONCILE_PAYMENT(?, ?, ?) }")) {
                call.setString(1, externalRef);
                call.registerOutParameter(2, Types.VARCHAR);
                call.registerOutParameter(3, Types.VARCHAR);
                call.execute();
                return new ConciliacionResponse(externalRef, call.getString(2), call.getString(3));
            }
        });
    }

    @Transactional(readOnly = true)
    public List<DiscrepanciaResponse> findDiscrepanciesLast24Hours() {
        String sql = """
            WITH es AS (
              SELECT payment_id,
                SUM(CASE WHEN provider_status='APPROVED' THEN 1 ELSE 0 END) approvals,
                SUM(CASE WHEN provider_status='DECLINED' THEN 1 ELSE 0 END) declines
              FROM PROVIDER_EVENT GROUP BY payment_id
            ), ls AS (
              SELECT payment_id,
                SUM(CASE WHEN entry_type='DEBIT' THEN amount WHEN entry_type='REVERSAL' THEN -amount ELSE 0 END) net_debit,
                SUM(CASE WHEN entry_type='DEBIT' THEN 1 ELSE 0 END) debit_count
              FROM LEDGER_ENTRY GROUP BY payment_id
            )
            SELECT p.external_ref, p.status, p.amount,
              NVL(ls.net_debit,0) net_debit, NVL(ls.debit_count,0) debit_count,
              NVL(es.approvals,0) approvals, NVL(es.declines,0) declines,
              CASE WHEN NVL(es.approvals,0)>0 AND NVL(es.declines,0)>0 THEN 'Evidencia contradictoria'
                   WHEN NVL(es.declines,0)>0 THEN 'Proveedor reporta rechazo'
                   WHEN NVL(es.approvals,0)=0 THEN 'Sin evidencia de aprobacion'
                   WHEN NVL(ls.net_debit,0)<>p.amount THEN 'Debito neto distinto al importe esperado'
                   WHEN NVL(ls.debit_count,0)>1 THEN 'Multiples debitos originales'
                   ELSE 'Estado requiere revision' END reason
            FROM PAYMENT p
            LEFT JOIN es ON es.payment_id=p.id
            LEFT JOIN ls ON ls.payment_id=p.id
            WHERE p.updated_at >= SYSTIMESTAMP - INTERVAL '24' HOUR
              AND ((NVL(es.approvals,0)>0 AND NVL(es.declines,0)>0)
                OR NVL(es.declines,0)>0 OR NVL(es.approvals,0)=0
                OR NVL(ls.net_debit,0)<>p.amount OR NVL(ls.debit_count,0)>1
                OR (p.status<>'CONFIRMED' AND NVL(ls.net_debit,0)=p.amount))
            ORDER BY p.updated_at DESC
            """;
        return jdbcTemplate.query(sql, (rs, n) -> new DiscrepanciaResponse(
          rs.getString("external_ref"), rs.getString("status"), rs.getBigDecimal("amount"),
          rs.getBigDecimal("net_debit"), rs.getLong("debit_count"), rs.getLong("approvals"),
          rs.getLong("declines"), rs.getString("reason")));
    }
}
