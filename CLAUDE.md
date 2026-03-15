# LegacyMCP — CLAUDE.md

## Cos'è questo progetto

LegacyMCP è un MCP (Model Context Protocol) server per Active Directory on-premises.
Permette a un LLM (Claude) di interrogare un ambiente AD reale, raccogliere dati di
assessment e rispondere a domande sulla configurazione del dominio.

Il progetto nasce come esperimento per dimostrare che l'AI può governare anche
l'infrastruttura legacy — non solo il cloud. È pubblicato su GitHub con licenza MIT
come progetto open source, con un layer enterprise proprietario sviluppato separatamente
da Impresoft 4ward.

Il progetto è creato da Marco Lelli, Head of Identity presso Impresoft 4ward,
società di consulenza IT specializzata in Microsoft Identity, e collegato al
blog Legacy Things (legacythings.it).

---

## Struttura del progetto

### Layer Open Source — LegacyMCP Core
Pubblicato su GitHub con licenza MIT.
Scope funzionale basato sullo script ADDS_Inventory.ps1 di Carl Webster (v3.20).
Riferimento: https://github.com/CarlWebster/Active-Directory-V3
Sola lettura assoluta. Nessuna modifica all'ambiente AD.

Copre:
- Forest info — nome, functional level, schema version, optional features (es. Recycle Bin)
- Schema AD — oggetti e attributi custom
- Domini — configurazione, functional level, password policy default
- Domain Controllers — lista, ruoli FSMO, OS version, configurazioni locali
  (incluse impostazioni registry NTP — recuperate contattando ogni DC individualmente)
- Event Log configuration — impostazioni EventLog per ogni DC
- SYSVOL — stato e replicazione
- Siti e site links — topologia di replicazione
- Utenti — conteggi, stati (abilitati/disabilitati/locked), last logon, account privilegiati
- Gruppi — gruppi privilegiati, membership, nested groups ricorsivi
- Organizational Units — struttura OU completa
- GPO Inventory — lista GPO per dominio, link alle OU, blocked inheritance
  (inventario, non analisi approfondita — quella è nel layer proprietario)
- Trust relationships — tipo, direzione, transitività, SIDHistory
- Fine-Grained Password Policies
- DNS — configurazione DNS dei Domain Controllers
- PKI / CA Discovery — Certification Authorities presenti in AD
  (CN=Public Key Services, CN=Enrollment Services)
  discovery automatica da AD, CN e Distinguished Name di ogni CA

NON incluso nel layer base:
- Analisi servizio DHCP — nel layer proprietario
- Analisi configurazione PKI — nel layer proprietario
- Analisi ESC path — nel layer proprietario

### Layer Proprietario — LegacyMCP Enterprise
Sviluppato internamente da Impresoft 4ward, non pubblicato open source.

Moduli pianificati:

**DHCP Analysis**
Discovery tramite Authorized DHCP Servers in AD (CN=NetServices)
o lista precompilata di server fornita dall'utente.

**GPO Analysis**
Analisi approfondita delle Group Policy — basata su GPOzaurr.
Va oltre l'inventario del layer base: analisi contenuto, conflitti,
policy ridondanti o non applicate.

**AD Security Analysis**
Analisi della sicurezza AD ispirata alla logica di PingCastle.
Findings con livello di rischio e indicazioni di remediation.

**AD Health Check**
Errori di configurazione, replication issues, best practice violations.
Complementare all'AD Security Analysis — focalizzato su salute operativa
più che su sicurezza.

**PKI / AD CS — tre livelli progressivi**
1. PKI Configuration Analysis — configurazione dettagliata di ogni CA,
   template pubblicati, validity period, chain of trust,
   CRL distribution points, AIA
2. PKI Security Analysis — misconfigurations, best practice,
   analisi configurazione in ottica sicurezza
3. ESC Analysis — analisi template vulnerabili (ESC1-ESC8)
   basata su documentazione pubblica Schroeder/Christensen.
   Identificazione escalation path nei template AD CS.

**Generazione documento DOCX**
Output automatico da template aziendale Impresoft 4ward.
I dati raccolti dal layer base e dai moduli proprietari
vengono riversati in un documento strutturato.
Zero formattazione manuale, zero copia-incolla.

---

## Modalità operative

LegacyMCP supporta due modalità operative con la stessa interfaccia verso Claude.

### Live Mode
Connessione diretta ai Domain Controllers via WinRM e PowerShell.
Richiede credenziali con diritti adeguati e accesso di rete ai DC.
Ideale per amministratori interni o consulenti con accesso diretto alla rete.
I dati sono freschi e interrogabili in tempo reale.

### Offline Mode
Un collector PowerShell raccoglie i dati AD e li esporta in un file JSON strutturato.
Il MCP server carica il JSON e lo converte internamente in SQLite per interrogazioni
efficienti. Il consulente lavora sul proprio PC con i dati esportati dall'ambiente
del cliente. Zero accesso di rete durante la fase di analisi.

Il file JSON è il formato di trasporto — leggibile, verificabile, trasportabile.
SQLite è il motore interno — mai esposto direttamente all'utente.

---

## Scope di lavoro — Workspace

LegacyMCP opera su scope variabili a seconda del contesto di assessment.

### Scenari supportati
- Singolo dominio — accesso limitato a un child domain, senza Enterprise Admin
- Foresta completa — accesso con Enterprise Admin, visione globale
- Foreste multiple standalone — clienti con ambienti separati
- Foreste multiple in relazione — migrazioni, M&A, trust cross-forest

### Concetto di Workspace
Un workspace definisce il contesto di lavoro corrente:
- Quali foreste e domini sono in scope
- Le credenziali associate a ciascuno (gMSA o account dedicato)
- Il tipo di relazione tra le foreste (standalone / source-destination / trust)
- La modalità operativa (Live o Offline)

### Offline Mode multi-scope
In Offline Mode ogni foresta o dominio produce un file JSON separato.
Il MCP server carica tutti i file in SQLite mantenendo una chiave sorgente
per ogni oggetto. Questo abilita controlli incrociati tra ambienti diversi.

### Caso d'uso migrazione
Quando il workspace contiene una foresta source e una destination, LegacyMCP
abilita query comparative:
- Utenti presenti in source ma non in destination
- Gruppi senza equivalente nel target
- Mapping SIDHistory per utenti già migrati
- Conflitti di naming tra i due ambienti

---

## Autenticazione al MCP Server

LegacyMCP supporta tre profili di deployment con configurazione di sicurezza diversa.
Il codice è unico — cambia il file di configurazione e le istruzioni di deployment.

### Profilo A — Offline Mode locale
Il MCP server gira sulla macchina del consulente.
Non esposto in rete — superficie di attacco zero.
Autenticazione: API key locale nel file di configurazione,
o solo localhost senza autenticazione esplicita.

### Profilo B — Live Mode in rete interna
Il MCP server gira su un server dentro la rete del cliente.
Accessibile solo dalla LAN aziendale.
Autenticazione: HTTPS su porta 443 con certificato interno,
API key o integrazione con Entra ID / AD FS per SSO aziendale.
Il gMSA gestisce l'accesso ad AD — l'autenticazione al MCP è separata.

### Profilo C — Live Mode esposto su internet
Scenario sconsigliato senza adeguate protezioni — esporre un MCP server AD
su internet è una superficie di attacco seria.

Requisiti minimi per rendere lo scenario accettabile:
- WAF (Web Application Firewall) obbligatorio davanti al MCP server
  — opzione naturale in ambito Microsoft: Azure Application Gateway con WAF,
  integrato con Entra ID e Microsoft Sentinel
  — alternative: Cloudflare WAF, AWS WAF
- TLS termination sul WAF — il MCP server parla HTTP interno
- HTTPS con certificato valido
- OAuth2 / OIDC con Entra ID come provider di identità
- MFA obbligatorio
- IP allowlisting — se i consulenti operano da paesi noti, bloccare tutto il resto
- Rate limiting
- Logging centralizzato di tutto il traffico in ingresso

Senza WAF: sconsigliato.
Con WAF e configurazione completa: accettabile con le dovute cautele.

---

## Principio architetturale fondamentale — Degradazione elegante

LegacyMCP opera spesso in ambienti parzialmente raggiungibili — DC in sedi remote,
firewall restrittivi, macchine in manutenzione.

Regole:
- Ogni operazione verso un DC ha un timeout configurabile
- Il fallimento su un DC non blocca la raccolta sugli altri
- Ogni dato ha un campo di stato: "completo" / "parziale" / "non raggiungibile"
- I DC irraggiungibili generano un warning nel EventLog dedicato, non un errore bloccante
- L'output finale indica chiaramente quali informazioni sono complete e quali parziali

---

## Requisiti tecnici

### PowerShell
- Versione minima: PowerShell 5.1
- Supporto opzionale: PowerShell 7.x
- Copertura: Windows Server 2012 R2 aggiornato a WMF 5.1 fino a Windows Server 2025

### MCP Server
- Linguaggio: Python
- SDK: mcp (SDK MCP ufficiale Anthropic)
- Formato dati interno: JSON (trasporto) + SQLite (interrogazione Offline Mode)

### Autenticazione ad AD
- Metodo preferito: gMSA (Group Managed Service Account)
- Il gMSA elimina la gestione manuale delle password
- Richiede che la macchina che ospita il servizio sia domain-joined

### Deployment come servizio Windows
- LegacyMCP può essere installato come servizio Windows
- Gestibile con strumenti standard Windows (sc, services.msc, PowerShell)
- Riavvio automatico in caso di crash

### EventLog dedicato
- LegacyMCP scrive in un EventLog dedicato (non nel log Application generico)
- Ogni operazione viene loggata: chi ha richiesto cosa, su quali oggetti,
  con quale risultato
- I DC irraggiungibili generano eventi di Warning
- Gli errori bloccanti generano eventi di Error
- Compatibile con SIEM, Microsoft Sentinel, e qualsiasi NPM del cliente

### Performance Counter — Heartbeat
- LegacyMCP espone un Performance Counter dedicato
- Contatore heartbeat: parte da zero all'avvio del servizio,
  si incrementa ogni N secondi
- Contatore DC: DC contattati con successo vs DC totali nell'ultimo ciclo
- Monitorabile con PerfMon, SCOM, e qualsiasi tool di monitoring Windows-based

---

## Cosa NON fare

- Non usare LDAP puro come unico metodo di accesso ad AD — manca il layer semantico
- Non ignorare errori di connessione ai DC — gestire sempre con degradazione elegante
- Non scrivere nell'Application EventLog generico — usare sempre il log dedicato
- Non hardcodare credenziali — usare sempre gMSA o configurazione esterna
- Non modificare mai oggetti AD nel layer open source — sola lettura assoluta
- Non usare PowerShell precedente a 5.1
- Non esporre il MCP server su internet senza WAF e autenticazione forte con MFA

---

## Contesto operativo tipico

I consulenti di Impresoft 4ward lavorano spesso da remoto, connessi in VPN alla rete
del cliente, su macchine di management del cliente. A volte in modalità desktop sharing.

- Live Mode: usato quando il consulente ha accesso diretto alla rete del cliente
- Offline Mode: usato quando il consulente lavora da remoto o in desktop sharing —
  il collector gira nel contesto del cliente, il JSON viene portato fuori
  e analizzato in ambiente separato

---

## Cronologia del progetto

- 13 marzo 2025 — Prima idea
- 14 marzo 2025 — Definizione scope, architettura, decisioni tecniche, avvio lavori.
  Installazione Claude Code, creazione repository, primi file.
- 15 marzo 2025 — Refinement architetturale: verifica coerenza con script Webster,
  workspace multi-scope, autenticazione MCP, profili di deployment,
  PKI strutturata in tre livelli progressivi, DHCP nel layer proprietario,
  GPO inventory nel layer base e analisi approfondita nel layer proprietario.