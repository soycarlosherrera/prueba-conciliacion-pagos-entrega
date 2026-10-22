# Prueba técnica: conciliación segura de pagos

## Objetivo
API REST Java/Spring Boot + Oracle para diagnosticar y conciliar pagos por referencia externa, preservando el ledger y evitando efectos duplicados.

## Requisitos
- Java 21
- Maven 3.9+
- Oracle Database Free con servicio `FREEPDB1`
- SQL Developer recomendado

## Orden de scripts
Para una base vacía: `01_create_schema.sql`, `02_seed_test_data.sql`, `06_create_sequences.sql`, `07_add_ledger_protection.sql`, `11_reconcile_payment.sql`, `05_validation_tests.sql`, `04_diagnostic_queries.sql`.


## Configuración Windows CMD

```bat
set DB_URL=jdbc:oracle:thin:@//localhost:1521/FREEPDB1
set DB_USERNAME=SYSTEM
set DB_PASSWORD=LA_CLAVE_LOCAL
mvn test
mvn spring-boot:run
```


## Endpoints
- `POST /api/payments/{externalRef}/reconcile`
- `GET /api/reconciliation/discrepancies`

Ejemplo:
```bash
curl -X POST http://localhost:8080/api/payments/PAY-BX17/reconcile
```
Respuesta:
```json
{"externalRef":"PAY-BX17","result":"MANUAL_REVIEW","message":"Existen multiples debitos originales."}
```

## Reglas
- Aprobación y ningún movimiento + estado PENDING: crear un débito por el importe esperado y confirmar en la misma transacción.
- Un débito correcto + aprobación + estado PENDING: confirmar sin crear otro débito.
- Confirmado y contabilizado correctamente: `NO_CHANGE`.
- Evidencias contradictorias, rechazo, falta de aprobación, múltiples débitos o diferencias contables: `MANUAL_REVIEW`.
- No se actualizan ni borran movimientos contables; una corrección debe ser un nuevo `REVERSAL` enlazado al débito original.
- No se revierte automáticamente PAY-BX17: el log no identifica inequívocamente cuál asiento debe revertirse.
- El procedimiento no hace COMMIT/ROLLBACK; Spring controla la transacción.

## Escenarios
- PAY-AX91: `CONFIRMED` en transacción de prueba y rollback posterior.
- PAY-BX17: `MANUAL_REVIEW`, conserva los dos débitos.
- PAY-CQ22: `MANUAL_REVIEW` por evidencia contradictoria.
- PAY-DK44: `NO_CHANGE`.
- Referencia inexistente: `NOT_FOUND`.
- Dos llamadas de revisión manual en la misma transacción deben producir una sola auditoría equivalente.

## Supuestos, riesgos y límites
Los datos de prueba incluyen supuestos donde el enunciado no da todas las columnas. El ID 5003 aparece en el log; su importe de 89.000 se asume para reproducir el total duplicado. Un timeout no demuestra rechazo. `SELECT ... FOR UPDATE` serializa llamadas al mismo pago. La consulta temporal filtra por `PAYMENT.updated_at`; como la semilla es histórica, puede devolver cero filas, por lo que se incluye una consulta sin filtro temporal. La prueba Java incluida es unitaria de la invocación JDBC, no una prueba de integración completa ni de concurrencia real. Ejecutar pruebas contra Oracle y dos sesiones concurrentes antes de afirmar validación end-to-end.

## Uso de IA
Se utilizó IA como apoyo para analizar requisitos, explorar alternativas, revisar casos límite y preparar documentación. La persona que entrega debe revisar, comprender y validar el código; la IA no sustituye la verificación técnica ni las pruebas.
