-- Como maximo una reversal por debito original.
CREATE UNIQUE INDEX UX_LEDGER_ONE_REVERSAL ON LEDGER_ENTRY
(CASE WHEN entry_type='REVERSAL' THEN related_entry_id END);
