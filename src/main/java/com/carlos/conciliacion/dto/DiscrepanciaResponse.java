package com.carlos.conciliacion.dto;
import java.math.BigDecimal;
public record DiscrepanciaResponse(String externalRef, String paymentStatus, BigDecimal expectedAmount,
 BigDecimal netDebit, long debitCount, long approvalCount, long declineCount, String reason) {}
