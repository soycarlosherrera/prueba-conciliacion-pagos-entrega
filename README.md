# Prueba técnica — Conciliación segura de pagos

## 1. Objetivo

Implementar una solución de soporte para diagnosticar y conciliar pagos identificados por una referencia externa, ante inconsistencias entre el estado del pago, la evidencia recibida del proveedor y los movimientos contables.

La solución combina una API REST en Java con Spring Boot y un procedimiento almacenado en Oracle. Busca que la conciliación sea idempotente, controle la concurrencia y preserve la trazabilidad contable. Cuando la evidencia no permite decidir con seguridad, el sistema conserva los datos y solicita revisión manual en lugar de realizar una corrección especulativa.

## 2. Resumen del incidente

El incidente de referencia muestra una llamada al proveedor que termina en timeout, un reintento, una respuesta `APPROVED` y más de un débito asociado a `PAY-BX17`. El timeout no demuestra que el proveedor haya rechazado el pago: solo indica que la respuesta no se recibió dentro del tiempo esperado. Por tanto, no es suficiente para decidir si se debe crear o revertir un asiento.

El objetivo de la conciliación es comparar tres fuentes:

- **PAYMENT:** referencia externa, estado, importe esperado y versión.
- **PROVIDER_EVENT:** eventos de aprobación o rechazo recibidos del proveedor.
- **LEDGER_ENTRY:** débitos y reversiones que representan los efectos contables.

Las decisiones y revisiones relevantes se registran en `SUPPORT_AUDIT`.

## 3. Alcance de la solución

- Consultar y conciliar un pago por su referencia externa.
- Calcular el débito neto como débitos menos reversiones.
- Identificar evidencia del proveedor ausente o contradictoria.
- Evitar crear un segundo débito cuando ya existe un débito original.
- Marcar para revisión manual los casos ambiguos o contablemente inconsistentes.
- Registrar auditoría de los resultados relevantes sin duplicar una auditoría equivalente en una repetición normal del procedimiento.
- Exponer una consulta de discrepancias de pagos actualizados durante las últimas 24 horas.
- Mantener los movimientos del ledger inmutables: las correcciones deben registrarse mediante una nueva reversión vinculada al débito original.

Fuera del alcance de esta entrega: invocar directamente al proveedor de pagos, determinar por sí sola la intención real de un asiento duplicado cuando no existe evidencia suficiente, y ejecutar una reversión automática en un caso ambiguo.

## 4. Arquitectura y componentes

```text
Cliente HTTP
	|
	v
ConciliacionController (Spring Boot REST)
	|
	v
ConciliacionService (@Transactional / JdbcTemplate)
	|
	v
Oracle: RECONCILE_PAYMENT
	|        |             |
	v        v             v
 PAYMENT  PROVIDER_EVENT  LEDGER_ENTRY
	|
	v
SUPPORT_AUDIT
```

### Componentes principales

- `ConciliacionController`: publica los endpoints HTTP.
- `ConciliacionService`: invoca el procedimiento almacenado mediante JDBC y ofrece la consulta de discrepancias.
- `RECONCILE_PAYMENT`: concentra las reglas de decisión en Oracle, bloquea la fila del pago durante la conciliación y registra auditoría cuando corresponde.
- `ApiExceptionHandler`: traduce excepciones de la API a respuestas HTTP.
- DTO de respuesta: define la estructura que devuelve la API.
- `database/`: contiene scripts de esquema, datos de prueba, secuencias, índice, diagnóstico y procedimiento.

## 5. Reglas de negocio y decisiones

1. **Evidencia contradictoria:** si existen eventos `APPROVED` y `DECLINED` para el mismo pago, el resultado es `MANUAL_REVIEW`.
2. **Sin aprobación suficiente:** si no hay un evento aprobado, no se confirma automáticamente el pago.
3. **Más de un débito original:** se solicita revisión manual. No se elige arbitrariamente cuál asiento revertir.
4. **Débito neto superior al importe esperado:** se solicita revisión manual; no se actualizan ni eliminan asientos existentes.
5. **Pago pendiente con una aprobación y un débito correcto:** puede confirmarse el estado sin generar otro débito.
6. **Pago pendiente con aprobación y sin movimientos contables:** el procedimiento puede crear el débito esperado y confirmar el pago dentro de la misma transacción.
7. **Pago confirmado y contabilizado correctamente:** el resultado es `NO_CHANGE`.
8. **Referencia inexistente:** se devuelve `NOT_FOUND`.
9. **Reversión inválida:** se envía a revisión manual si no apunta a un débito del mismo pago o si excede el importe del débito original.
10. **Auditoría repetida:** antes de insertar una auditoría, el procedimiento busca una acción y razón equivalentes para ese pago.

El procedimiento no ejecuta `COMMIT` ni `ROLLBACK`; la transacción se gestiona desde Spring. La consulta `SELECT ... FOR UPDATE` bloquea la fila del pago para serializar solicitudes concurrentes que intenten conciliar la misma referencia.

## 6. API REST

### Conciliar un pago

```http
POST /api/payments/{externalRef}/reconcile
```

Ejemplo:

```bash
curl -X POST http://localhost:8080/api/payments/PAY-BX17/reconcile
```

Respuesta ilustrativa:

```json
{
  "externalRef": "PAY-BX17",
  "result": "MANUAL_REVIEW",
  "message": "Existen multiples debitos originales."
}
```

Resultados que puede devolver el procedimiento: `CONFIRMED`, `NO_CHANGE`, `MANUAL_REVIEW` y `NOT_FOUND`.

### Consultar discrepancias recientes

```http
GET /api/reconciliation/discrepancies
```

Devuelve pagos actualizados durante las últimas 24 horas que cumplen las condiciones de discrepancia implementadas en la consulta. El resultado incluye referencia, estado, importe esperado, débito neto, cantidad de débitos, eventos aprobados/rechazados y una razón de diagnóstico.

**Nota temporal:** los datos de prueba tienen fechas históricas del 13 de octubre de 2026. Si la consulta se ejecuta fuera de las 24 horas siguientes a esas fechas, es normal que no devuelva esos registros. Para probar el endpoint temporal, actualiza las fechas de prueba de forma controlada o utiliza los datos en un entorno recién preparado. No se debe eliminar el filtro temporal en producción solo para hacer aparecer datos antiguos.

## 7. Escenarios de prueba y resultados observados

Los datos iniciales son fixtures de prueba construidos a partir del incidente y de los ejemplos del enunciado. Los campos o movimientos no especificados en el documento se identifican como supuestos, no como hechos del incidente real.

| Referencia | Situación preparada | Resultado esperado/observado | Motivo |
|---|---|---|---|
| `PAY-AX91` | `PENDING`, una aprobación y un débito por 125.000 | `CONFIRMED` al conciliar | Evidencia aprobada y débito correcto; se actualiza el estado sin crear otro débito. |
| `PAY-BX17` | `CONFIRMED`, dos aprobaciones y dos débitos de 89.000; neto 178.000 | `MANUAL_REVIEW` | Hay más de un débito original; no se revierte ninguno automáticamente. |
| `PAY-CQ22` | `PENDING`, una aprobación y un rechazo, sin débitos | `MANUAL_REVIEW` | Evidencia contradictoria del proveedor. |
| `PAY-DK44` | `CONFIRMED`, una aprobación y un débito por 31.000 | `NO_CHANGE` | El pago ya está conciliado correctamente. |
| Referencia inexistente | No existe pago para esa referencia | `NOT_FOUND` | No se encuentra el pago solicitado. |

También se realizaron comprobaciones de reglas de reversión sin insertar una reversión real: se validó que el débito original pertenezca al mismo pago, que sea un débito, y que el importe propuesto no supere el saldo pendiente de revertir. La comprobación de un importe superior al débito se consideró inválida.

### Resultado contable de los datos de prueba

| Referencia | Débitos | Reversiones | Débito neto | Importe esperado |
|---|---:|---:|---:|---:|
| `PAY-AX91` | 125.000 | 0 | 125.000 | 125.000 |
| `PAY-BX17` | 178.000 | 0 | 178.000 | 89.000 |
| `PAY-CQ22` | 0 | 0 | 0 | 54.000 |
| `PAY-DK44` | 31.000 | 0 | 31.000 | 31.000 |

Los valores son pesos/unidades monetarias de los datos de ejemplo del ejercicio; no se afirma que representen transacciones reales.

## 8. Hipótesis y datos que requieren confirmación

- El identificador `5003` aparece en el log del incidente como un débito. El importe de 89.000 asociado a ese movimiento se usa como hipótesis de prueba para reproducir el neto duplicado.
- El segundo débito de `PAY-BX17`, el segundo evento aprobado y varios identificadores de los fixtures son datos sintéticos agregados para poder probar el caso de duplicidad.
- Se asume que cada evento de proveedor registrado es evidencia que debe analizarse, pero no se dispone de un contrato real del proveedor ni de una regla que permita determinar cuál de los dos débitos es el incorrecto.
- Se asume que `PAYMENT.amount` es el importe esperado y que el débito neto se calcula como `DEBIT - REVERSAL`.
- Antes de corregir datos reales, deben confirmarse los identificadores de transacción del proveedor, los identificadores de asientos, la regla oficial de idempotencia y el procedimiento contable aprobado para reversar.

Estas hipótesis se usan para construir una prueba reproducible. No deben convertirse en datos de producción sin verificación.

## 9. Riesgos, limitaciones y medidas propuestas

- **Reversión equivocada:** revertir sin evidencia suficiente puede agravar la inconsistencia. Medida: revisión manual y confirmación del asiento original antes de corregir.
- **Concurrencia:** la fila del pago se bloquea durante el procedimiento. Aun así, debe validarse con dos sesiones reales de Oracle antes de considerar demostrada la concurrencia de extremo a extremo.
- **Idempotencia de auditoría:** la búsqueda de una auditoría equivalente funciona dentro del flujo normal y con el bloqueo del pago. Para una garantía más fuerte frente a otros procesos concurrentes que escriban auditoría por fuera de este procedimiento, se recomienda una restricción única adecuada al modelo operativo.
- **Reversiones:** el índice único impide más de una reversión para el mismo asiento original. Si el negocio permite reversiones parciales múltiples, esa regla debe rediseñarse junto con la validación del importe acumulado.
- **Ventana de 24 horas:** el endpoint utiliza `PAYMENT.updated_at`; un pago con evidencia nueva pero sin actualización reciente del registro de pago podría no aparecer. Para producción se debería acordar si la ventana debe basarse en la última evidencia, el último movimiento contable o una combinación de tiempos.
- **Consulta de discrepancias:** sus reglas son diagnósticas y no reemplazan la conciliación transaccional. La decisión final se realiza mediante el procedimiento almacenado.
- **Cobertura de pruebas:** el test Java incluido es unitario y verifica la invocación JDBC con dobles de prueba. No demuestra por sí solo el funcionamiento integrado con Oracle ni la concurrencia real.

## 10. Requisitos y ejecución local

### Requisitos

- JDK 21.
- Maven 3.9 o superior.
- Oracle Database Free, con el servicio `FREEPDB1` accesible en `localhost:1521`.
- Docker Desktop, si Oracle Database Free se ejecuta en un contenedor.
- SQL Developer (recomendado para ejecutar e inspeccionar los scripts).

### Oracle Database en Docker

El contenedor Oracle debe estar iniciado y publicar el puerto `1521` en el equipo local. Para revisar el contenedor existente:

```bat
docker ps -a --filter "name=oracle-free"
```

Si aparece detenido, puedes iniciarlo con:

```bat
docker start oracle-free
```

Comprueba que el puerto de Oracle esté publicado:

```bat
docker port oracle-free 1521
```

La aplicación se conecta desde Windows a `localhost:1521/FREEPDB1`; no necesita ejecutarse dentro del contenedor. Si el contenedor ya está activo y el puerto está publicado, no hace falta recrearlo.

### Preparación de la base de datos

En una base vacía, ejecutar en este orden:

1. `database/01_create_schema.sql`
2. `database/02_seed_test_data.sql`
3. `database/06_create_sequences.sql`
4. `database/07_add_ledger_protection.sql`
5. `database/11_reconcile_payment.sql`
6. `database/05_validation_tests.sql`
7. `database/04_diagnostic_queries.sql`

Ejecuta los scripts de creación con el usuario de práctica previsto y revisa que cada uno termine sin errores. Si las tablas, los datos, las secuencias y el índice ya existen, **no vuelvas a ejecutar los scripts de creación ni de inserción**. En ese caso, ejecuta `11_reconcile_payment.sql` para instalar la versión actual del procedimiento y luego las consultas de validación. Ejecuta el script del procedimiento con **F5 / Run Script** en SQL Developer para que se procese el `/` final.

Los archivos numerados con versiones anteriores se conservan como referencia de evolución; no es necesario ejecutarlos si ya se utiliza `11_reconcile_payment.sql`.

### Configuración de conexión en Windows CMD

Desde la raíz del proyecto, define las variables de entorno en la misma ventana en la que ejecutarás Maven:

```bat
set DB_URL=jdbc:oracle:thin:@//localhost:1521/FREEPDB1
set DB_USERNAME=SYSTEM
set DB_PASSWORD=TU_CLAVE_LOCAL
mvn test
mvn spring-boot:run
```

Reemplaza `TU_CLAVE_LOCAL` por la contraseña configurada en tu entorno. No incluyas la contraseña en el repositorio ni en capturas o documentación compartida. Para un entorno de producción se debe utilizar una cuenta de base de datos con permisos mínimos, no `SYSTEM`.

### Comprobación manual de los endpoints

Con la aplicación iniciada, prueba en otra terminal:

```bat
curl -X POST http://localhost:8080/api/payments/PAY-BX17/reconcile
curl http://localhost:8080/api/reconciliation/discrepancies
```

El primer endpoint debería devolver `MANUAL_REVIEW` para el fixture `PAY-BX17`. El segundo puede devolver una lista vacía si los registros de prueba quedan por fuera de la ventana temporal de 24 horas.

## 11. Verificación realizada y pendiente

**Comprobaciones realizadas en Oracle durante el desarrollo:**

- Creación de las tablas y restricciones del esquema.
- Inserción de los datos de prueba y consulta de débitos, reversiones y débito neto.
- Creación de secuencias y del índice único para vincular una reversión a un solo débito original.
- Compilación del procedimiento `RECONCILE_PAYMENT`.
- Ejecución de escenarios de conciliación para `PAY-AX91`, `PAY-BX17`, `PAY-CQ22` y `PAY-DK44`.
- Comprobación de que `PAY-BX17` se mantiene en revisión manual y conserva los dos débitos.
- Validaciones exploratorias de las reglas de reversión sin insertar movimientos de reversión reales.

**Pendiente antes de considerar la entrega validada de extremo a extremo:**

- Ejecutar `mvn test` en el equipo de entrega y registrar el resultado real.
- Iniciar la aplicación y comprobar los dos endpoints HTTP.
- Confirmar que Spring Boot se conecta a la instancia Oracle local con las variables de entorno configuradas.
- Ejecutar pruebas de concurrencia con dos sesiones o solicitudes simultáneas.
- Revisar el código final y comprobar que coincide con los scripts instalados en Oracle.

No se afirma que las pruebas de integración o de concurrencia estén completas hasta que se ejecuten y se revisen sus resultados.

## 12. Uso de herramientas de IA

Se utilizó una herramienta de IA como apoyo durante el análisis del enunciado, la exploración de alternativas de diseño, la preparación y revisión del código, la identificación de casos límite y la organización de la documentación.

Ante la falta del historial Git original, se inicializó un repositorio y se organizaron commits temáticos a partir de los scripts SQL disponibles, la estructura actual del proyecto y las sentencias que aún estaban visibles en la caché de Oracle. Esta secuencia es una reconstrucción posterior y no representa necesariamente las fechas ni el orden exactos del desarrollo original. La caché SQL es parcial y temporal, por lo que se utilizó solo como referencia complementaria.

## 13. Cierre

La decisión principal de esta solución es no confundir un reintento o un timeout con una prueba de rechazo y no corregir automáticamente un ledger cuando la evidencia es insuficiente. Para los casos consistentes, el procedimiento permite completar o reconocer la conciliación; para los casos ambiguos, conserva los datos, deja trazabilidad y deriva la decisión a revisión manual. Antes de utilizar un enfoque similar en producción, deben validarse las reglas con los responsables del proveedor y de contabilidad, y completar las pruebas de integración y concurrencia.
