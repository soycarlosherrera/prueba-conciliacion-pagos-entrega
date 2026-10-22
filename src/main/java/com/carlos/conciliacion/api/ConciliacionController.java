package com.carlos.conciliacion.api;
import com.carlos.conciliacion.dto.*;
import com.carlos.conciliacion.service.ConciliacionService;
import jakarta.validation.constraints.NotBlank;
import org.springframework.http.ResponseEntity;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.*;
import java.util.List;
@RestController
@RequestMapping("/api")
@Validated
public class ConciliacionController {
    private final ConciliacionService service;
    public ConciliacionController(ConciliacionService service) { this.service = service; }
    @PostMapping("/payments/{externalRef}/reconcile")
    public ResponseEntity<ConciliacionResponse> reconcile(@PathVariable @NotBlank String externalRef) {
        ConciliacionResponse response = service.reconcile(externalRef);
        return "NOT_FOUND".equals(response.result()) ? ResponseEntity.notFound().build() : ResponseEntity.ok(response);
    }
    @GetMapping("/reconciliation/discrepancies")
    public List<DiscrepanciaResponse> discrepancies() { return service.findDiscrepanciesLast24Hours(); }
}
