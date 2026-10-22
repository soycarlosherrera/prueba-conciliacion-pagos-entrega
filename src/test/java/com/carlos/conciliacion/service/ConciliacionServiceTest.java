package com.carlos.conciliacion.service;
import com.carlos.conciliacion.dto.ConciliacionResponse;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import java.sql.CallableStatement;
import java.sql.Connection;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;
class ConciliacionServiceTest {
 @Test void llamaAlProcedimientoYDevuelveResultado() throws Exception {
   JdbcTemplate jdbc = mock(JdbcTemplate.class);
   Connection connection = mock(Connection.class);
   CallableStatement call = mock(CallableStatement.class);
   when(jdbc.execute(any(ConnectionCallback.class))).thenAnswer(inv -> {
     ConnectionCallback<?> cb = inv.getArgument(0); return cb.doInConnection(connection);
   });
   when(connection.prepareCall("{ call RECONCILE_PAYMENT(?, ?, ?) }")).thenReturn(call);
   when(call.getString(2)).thenReturn("MANUAL_REVIEW");
   when(call.getString(3)).thenReturn("Existen multiples debitos originales.");
   ConciliacionResponse response = new ConciliacionService(jdbc).reconcile("PAY-BX17");
   assertEquals("PAY-BX17", response.externalRef());
   assertEquals("MANUAL_REVIEW", response.result());
   verify(call).setString(1, "PAY-BX17");
   verify(call).execute();
 }
}
