CREATE OR REPLACE PROCEDURE RECONCILE_PAYMENT (
 p_external_ref IN VARCHAR2, p_result OUT VARCHAR2, p_message OUT VARCHAR2
)
IS
 v_payment_id PAYMENT.id%TYPE; v_status PAYMENT.status%TYPE; v_amount PAYMENT.amount%TYPE;
 v_approvals NUMBER:=0; v_declines NUMBER:=0; v_net_debit NUMBER:=0;
 v_debit_count NUMBER:=0; v_reversal_count NUMBER:=0; v_entry_count NUMBER:=0;
 v_invalid_reversal NUMBER:=0; v_audit_count NUMBER:=0; v_reason VARCHAR2(400);
BEGIN
 SELECT id,status,amount INTO v_payment_id,v_status,v_amount
 FROM PAYMENT WHERE external_ref=p_external_ref FOR UPDATE;

 SELECT NVL(SUM(CASE WHEN provider_status='APPROVED' THEN 1 ELSE 0 END),0),
        NVL(SUM(CASE WHEN provider_status='DECLINED' THEN 1 ELSE 0 END),0)
 INTO v_approvals,v_declines FROM PROVIDER_EVENT WHERE payment_id=v_payment_id;

 SELECT NVL(SUM(CASE WHEN entry_type='DEBIT' THEN amount WHEN entry_type='REVERSAL' THEN -amount ELSE 0 END),0),
        NVL(SUM(CASE WHEN entry_type='DEBIT' THEN 1 ELSE 0 END),0),
        NVL(SUM(CASE WHEN entry_type='REVERSAL' THEN 1 ELSE 0 END),0),COUNT(*)
 INTO v_net_debit,v_debit_count,v_reversal_count,v_entry_count
 FROM LEDGER_ENTRY WHERE payment_id=v_payment_id;

 SELECT COUNT(*) INTO v_invalid_reversal
 FROM LEDGER_ENTRY r LEFT JOIN LEDGER_ENTRY d ON d.id=r.related_entry_id
 WHERE r.payment_id=v_payment_id AND r.entry_type='REVERSAL'
 AND (d.id IS NULL OR d.entry_type<>'DEBIT' OR d.payment_id<>r.payment_id OR r.amount>d.amount);

 IF v_invalid_reversal>0 THEN
   p_result:='MANUAL_REVIEW'; v_reason:='Se detectaron reversiones con relacion o importe invalido.';
 ELSIF v_approvals>0 AND v_declines>0 THEN
   p_result:='MANUAL_REVIEW'; v_reason:='Existen evidencias contradictorias del proveedor.';
 ELSIF v_declines>0 THEN
   p_result:='MANUAL_REVIEW'; v_reason:='Existe evidencia de rechazo del proveedor.';
 ELSIF v_approvals=0 THEN
   p_result:='MANUAL_REVIEW'; v_reason:='No existe evidencia suficiente de aprobacion.';
 ELSIF v_debit_count>1 THEN
   p_result:='MANUAL_REVIEW'; v_reason:='Existen multiples debitos originales.';
 ELSIF v_net_debit>v_amount THEN
   p_result:='MANUAL_REVIEW'; v_reason:='El debito neto supera el importe esperado.';
 ELSIF v_entry_count=0 AND v_status='PENDING' THEN
   INSERT INTO LEDGER_ENTRY(id,payment_id,entry_type,amount,related_entry_id,created_at)
   VALUES(SEQ_LEDGER_ENTRY.NEXTVAL,v_payment_id,'DEBIT',v_amount,NULL,SYSTIMESTAMP);
   UPDATE PAYMENT SET status='CONFIRMED',updated_at=SYSTIMESTAMP,row_version=row_version+1
   WHERE id=v_payment_id AND status='PENDING';
   IF SQL%ROWCOUNT<>1 THEN RAISE_APPLICATION_ERROR(-20001,'No fue posible confirmar el pago.'); END IF;
   p_result:='CONFIRMED'; v_reason:='Pago confirmado y debito creado con evidencia aprobada.';
 ELSIF v_net_debit=v_amount AND v_debit_count=1 AND v_entry_count=1 AND v_reversal_count=0 THEN
   IF v_status='CONFIRMED' THEN
     p_result:='NO_CHANGE'; p_message:='El pago ya esta conciliado correctamente.'; RETURN;
   ELSIF v_status='PENDING' THEN
     UPDATE PAYMENT SET status='CONFIRMED',updated_at=SYSTIMESTAMP,row_version=row_version+1
     WHERE id=v_payment_id AND status='PENDING';
     IF SQL%ROWCOUNT<>1 THEN RAISE_APPLICATION_ERROR(-20002,'El estado cambio inesperadamente.'); END IF;
     p_result:='CONFIRMED'; v_reason:='Pago confirmado con evidencia aprobada y debito correcto.';
   ELSE
     p_result:='MANUAL_REVIEW'; v_reason:='El estado actual no permite confirmar automaticamente.';
   END IF;
 ELSIF v_entry_count=0 AND v_status='CONFIRMED' THEN
   p_result:='MANUAL_REVIEW'; v_reason:='El pago figura confirmado pero no tiene movimientos contables.';
 ELSE
   p_result:='MANUAL_REVIEW'; v_reason:='La situacion contable requiere revision manual.';
 END IF;

 IF p_result IN ('CONFIRMED','MANUAL_REVIEW') THEN
   SELECT COUNT(*) INTO v_audit_count FROM SUPPORT_AUDIT
   WHERE payment_id=v_payment_id AND action=p_result AND reason=v_reason;
   IF v_audit_count=0 THEN
     INSERT INTO SUPPORT_AUDIT(id,payment_id,action,reason,created_at)
     VALUES(SEQ_SUPPORT_AUDIT.NEXTVAL,v_payment_id,p_result,v_reason,SYSTIMESTAMP);
   END IF;
   p_message:=v_reason;
 END IF;
EXCEPTION
 WHEN NO_DATA_FOUND THEN p_result:='NOT_FOUND'; p_message:='No existe un pago con esa referencia.';
END RECONCILE_PAYMENT;
/
