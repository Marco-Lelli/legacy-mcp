# Skill: /session-close

## Scopo
Applicare il delta di sessione ai file ST-* in /status/.
Operazione chirurgica: nessuna sintesi libera, nessuna modifica fuori dal delta.

## Invocazione
```
/session-close delta-NN
```
Dove NN e' il numero sessione. Il file si trova in `status/delta/delta-NN.md`.

---

## Procedura

### 1. Leggi il delta
Leggi integralmente `status/delta/delta-NN.md`.
Non interpretare — applica letteralmente ogni sezione presente.
Sezioni assenti nel delta = nessuna modifica per quell'area.

### 2. Applica le modifiche per file

#### ST-status.md
- **AGGIORNA Stato corrente**: sostituisci il blocco grassetto iniziale
  con il testo della sezione "Stato corrente"
- **AGGIORNA Commit piu' recente**: aggiorna il campo nel blocco iniziale
- **AGGIORNA File unstaged**: aggiorna la lista (o rimuovi se "nessuno")
- **AGGIORNA Release**: aggiorna se presente nel delta
- **CHIUDI task**: per ogni task elencato, sposta da ⏳ a ✅ nella task list
- **AGGIUNGI task urgenti**: aggiungi sotto "Task aperti urgenti"
- **AGGIUNGI problemi aperti**: aggiungi nella sezione "Problemi aperti con contesto"

#### ST-backlog.md
- **AGGIUNGI task backlog**: appendi i nuovi task ⏳ mantenendo l'ordinamento numerico

#### ST-envs.md
- **AGGIORNA Ambienti**: per ogni macchina o sezione indicata nel delta,
  aggiorna solo le righe specificate. Non riscrivere sezioni non toccate.
  Se la sezione non e' presente: nessuna modifica.

#### ST-arch.md
- **AGGIUNGI decisioni architetturali**: aggiungi nella sezione indicata
  (crea la sezione se non esiste)
- **AGGIUNGI note tecniche**: appendi nella sezione "Note tecniche varie"

#### ST-history.md
- **AGGIUNGI cronologia**: appendi la voce in fondo alla sezione "Cronologia del progetto"
- **AGGIORNA numeri chiave**: aggiorna i valori esistenti o aggiungi nuove voci

### 3. Mostra il diff
Esegui:
```bash
git diff status/ST-status.md
git diff status/ST-backlog.md
git diff status/ST-envs.md
git diff status/ST-arch.md
git diff status/ST-history.md
```
Riporta il diff completo e attendi approvazione esplicita prima di procedere.

### 4. Completato
/status/ è gitignored — nessun commit necessario.
Le modifiche ai file ST-* sono locali by design.
Comunica a Marco il riepilogo delle modifiche applicate e chiudi.
```

---

## Regole ferree

- **Non modificare nessun file fuori da /status/**
- **Non modificare PRINCIPLES.md**
- **Non toccare file Python, PowerShell, o qualsiasi file sorgente**
- **Non fare sintesi, interpretazioni, o miglioramenti redazionali**
  — applica il delta verbatim
- **Non committare senza diff approvato**
- Se una sezione del delta e' ambigua o il punto di inserimento non e' chiaro,
  fermati e chiedi — non fare assunzioni

---

## In caso di errore

Se un file ST-* risulta corrotto dopo l'applicazione:
```bash
git checkout status/ST-[nome].md
```
Riparti dal delta e applica una sezione alla volta.
