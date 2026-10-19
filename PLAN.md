# S.U.R.V.I.V.E

|**S**|Stay calm|
|---|---|
|**U**|Understand your situation|
|**R**|Respond with reason|
|**V**|Value your resources|
|**I**|Improvise when needed|
|**V**|Visualize success|
|**E**|Endure everything|

**Nazwa grupy:** Grupa 6D **Osoby:** Adam Podymniak, Karolina Rutkowska, Bartosz Sikora
## Tematyka projektu

Tanie urządzenie oparte na architekturze LoRa (Meshtastic) oraz własny system określania lokalizacji i przesyłania danych o zagrożeniach, punktach sanitarnych, punktach ewakuacji itp. w strefach wojennych, gdzie konwencjonalne sygnały (GPS, WiFi) są zakłócane. Projekt jest przeznaczony dla cywilów i służb humanitarnych, aby mogli porozumiewać się między sobą i przekazywać informacje o stanie szpitali polowych, magazynów zasobów, liczbie osób itp.

## Technologie

|Warstwa|Technologia|
|---|---|
|Aplikacja mobilna|Flutter + `osm_flutter_plugin` (mapy OSM offline), `drift`/SQLite, Riverpod lub BLoC|
|Tanie urządzenie|ESP32-WROOM + SX1280 (2,4 GHz, sprzętowy ranging) + SX126x/SX127x (868 MHz, transport danych) + Radio LoRa|
|Firmware|Fork Meshtastic z nową funkcjonalnością (C/C++, FreeRTOS, nanopb)|

---

# 1. Działanie aplikacji (krok po kroku)

## 1.1 Ustalanie lokalizacji bez GPS (w tym PoC ranging)

1. **Zapamiętanie pozycji.** Węzły stacjonarne, które utraciły GPS, utrzymują ostatnią znaną lokalizację i ją zwracają. Ponieważ są statyczne, zapisana wartość pozostaje poprawna. Każdy węzeł przechowuje też flagę `positionSource` (`GPS_FIX`, `GPS_STALE`, `MANUAL`, `TRILATERATED`) oraz `positionAge`.
2. **Zapytanie o koordynaty.** Urządzenie rozgłasza `POSITION_REQUEST` do węzłów w zasięgu bezpośrednim (bez przeskoków) i zbiera odpowiedzi `POSITION_RESPONSE` (koordynaty + `positionSource` + `positionAge`).
3. **Pomiar dystansu (PoC ranging).** Do każdego z odpowiadających węzłów wykonywany jest "ranging" na SX1280. Dokonywanych jest kilka pomiarów na węzeł (np. 8-16) i odrzucenie wartości odstających (mediana + MAD). Dystans: `d = c · (t_roundtrip − t_processing) / 2` (może ulec zmianie przy testowaniu)
4. **Wybór optymalnych 2/3 węzłów.** Algorytm ocenia kandydatów według kryteriów:
    - bliskość (mniejszy dystans = mniejszy błąd bezwzględny),
    - geometria (kąt między kierunkami do węzłów jak najbliższy 90° dla 2 węzłów lub trójkąt jak najbardziej „rozłożony" dla 3),
    - jakość danych (świeża pozycja, `GPS_FIX` > `GPS_STALE`, niskie odchylenie pomiarów). Wynik to ranking `score = w1·(1/d) + w2·geometry + w3·quality`, a następnie wybór najlepszej podgrupy (przy 5-6 kandydatach to tylko kilkanaście kombinacji, więc nie ma problemu wydajnościowego).
5. **Obliczenie lokalizacji.**
    - **3 węzły:** trilateracja (liniowy układ równań po odjęciu równań okręgów, w razie nadmiarowości metoda najmniejszych kwadratów).
    - **2 węzły:** dają dwa rozwiązania (punkty przecięcia okręgów). Wybierane jest to zgodne z ostatnią znaną pozycją lub kierunkiem ruchu, a wynik jest oznaczany jako `LOW_CONFIDENCE`.
    - Współrzędne geograficzne są przeliczane do lokalnego układu płaskiego (ENU / równoprostokątne), a po obliczeniach z powrotem na WGS84.
    - Wynik zawiera szacowany błąd (promień niepewności), który wyświetla aplikacja jako okrąg na mapie.

```mermaid
sequenceDiagram
    participant U as Urządzenie użytkownika
    participant A as Węzeł A
    participant B as Węzeł B
    participant C as Węzeł C
    U->>A: POSITION_REQUEST (hop=0)
    U->>B: POSITION_REQUEST (hop=0)
    U->>C: POSITION_REQUEST (hop=0)
    A-->>U: POSITION_RESPONSE (lat, lon, age)
    B-->>U: POSITION_RESPONSE (lat, lon, age)
    C-->>U: POSITION_RESPONSE (lat, lon, age)
    U->>A: RANGING (SX1280, N pomiarów)
    U->>B: RANGING
    U->>C: RANGING
    Note over U: Filtr outlierów, wybór 2/3 węzłów, trilateracja
    U->>U: Zapis pozycji + promień niepewności
```

## 1.2 Zabezpieczenie komunikacji

1. W wypadku użycia zakłócaczy (jammerów) słaby sygnał GPS zostanie łatwo wyeliminowany.
2. W wypadku użycia zakłócaczy o większej mocy może zostać odcięty dostęp do WiFi.
3. LoRa działająca na 868 MHz z modulacją rozproszonego widma (CSS, chirp) jest znacznie odporniejsza na zakłócenia, dlatego komunikacja między urządzeniami może pozostać nienaruszona. Meshtastic/MeshCore mają pełne systemy wymiany wiadomości tekstowych (publiczne/prywatne).

## 1.3 Enkodowanie / dekodowanie dla optymalizacji przesyłu

LoRa ma mały payload (ok. 237 B w Meshtastic) i niski duty cycle (868 MHz w UE: 1% lub 10% zależnie od podpasma). Każdy bajt zmniejsza czas w eterze, więc wiadomość o punkcie musi być binarna i zwięzła.

**Założenia kodeka (`PoiCodec`):**

- Protobuf (nanopb) dla zgodności z Meshtastic, a w ramach niego **własne pola upakowane bitowo** dla najczęstszych zdarzeń.
- Pozycja jako `int32` w jednostkach 1e-7 stopnia (jak w Meshtastic).
- Czas jako `uint32` minut od epoki ustalonej w projekcie (zamiast sekund Unix).
- TTL jako `uint8` w jednostkach 5 minut (0–21 godzin) z kodem specjalnym `0xFF` = bez wygaśnięcia.

**Przykładowy układ pakietu POI (cel: ≤ 24 B):**

|Pole|Bity|Opis|
|---|---|---|
|`version`|3|wersja formatu|
|`type`|5|32 typy POI (`PointOfInterestType`)|
|`status`|2|`ACTIVE / AT_CAPACITY / DESTROYED / UNKNOWN`|
|`verification`|2|`OFFICIAL / NGO_VERIFIED / CROWDSOURCED / UNVERIFIED`|
|`reserved`|4|zapas|
|`id`|32|skrót (hash) identyfikatora|
|`lat`, `lon`|2×32|pozycja bezwzględna|
|`timestamp`|32|minuty od epoki projektu|
|`ttl`|8|jednostki po 5 min|
|`metaMask` + `meta`|8 + n|opcjonalne pola (pojemność, liczba osób, lek itd.)|
|`crc16`|16|kontrola spójności|

**Dodatkowe optymalizacje:**

- Deduplikacja po `id` + `timestamp` (flooding w mesh nie powinien rozsyłać tej samej informacji wielokrotnie).
- Priorytety: `SOS_BEACON` > zagrożenia > ewakuacja > zasoby > reszta (kolejka priorytetowa w nadawaniu).

## 1.4 Wymiana P2P i zaufanie

- Wymiana P2P (Peer-to-Peer) z możliwością wybierania węzłów zaufanych i usuwania węzłów zakłócających.
- **Lista zaufania (whitelist / blacklist)** przechowywana lokalnie.
- **Automatyczne ignorowanie** węzła, który przekracza próg spamu (np. > N pakietów/min) lub nadaje niepoprawne pakiety. Użytkownik może to cofnąć ręcznie.

## 1.5 Automat stanów urządzenia

```mermaid
stateDiagram-v2
    [*] --> Boot
    Boot --> GpsLock: GPS fix OK
    Boot --> NoGps: brak GPS
    GpsLock --> NoGps: utrata GPS / jamming
    NoGps --> Ranging: żądanie pozycji
    Ranging --> Positioned: min. 2-3 węzły
    Ranging --> NoGps: brak węzłów / timeout
    Positioned --> NoGps: pozycja przeterminowana
```

---

# 2. Dane

## 2.1 Zakres danych (kategorie)

### Infrastruktura medyczna i zdrowotna

- **Szpitale polowe i przychodnie:** status operacyjny, możliwości leczenia urazów i limity miejsc.
- **Apteki i składy medyczne:** dostępność krytycznych leków (insulina, antybiotyki, stazy taktyczne, jod).

### Zagrożenia i bezpieczeństwo

- **Niewybuchy (UXO) i pola minowe:** znane lub podejrzewane niewybuchy, miny lądowe i zaminowana infrastruktura.
- **Strefy aktywnych walk:** aktualne linie frontu, obszary potyczek i strefy niedawnych uderzeń artylerii/lotnictwa.
- **Aleje snajperów i wrogie punkty kontrolne:** korytarze o wysokim ryzyku i wojskowe blokady drogowe.

### Ewakuacja i bezpieczne przemieszczanie się

- **Korytarze humanitarne:** oficjalne bezpieczne trasy, w tym uzgodnione okna zawieszenia broni i godziny otwarcia/zamknięcia.
- **Punkty zbiórki do ewakuacji:** wyznaczone miejsca zbiórek dla ewakuacji przez organizacje pozarządowe lub rząd.
- **Schrony:** schrony przeciwbombowe, wzmocnione piwnice, podziemne stacje metra i wyznaczone bezpieczne strefy ONZ.

### Zasoby niezbędne

- **Punkty poboru wody (WASH):** studnie z wodą pitną, beczkowozy i punkty oczyszczania wody.

### Zgłaszanie incydentów i metadane od społeczności

- **Tagi czasu życia (TTL):** dane o wygaśnięciu dla tymczasowych zagrożeń (np. usunięcie blokady drogowej lub przesunięcie linii frontu).
- **Poziomy weryfikacji:** poziomy zaufania odróżniające zweryfikowane dane NGO, oficjalne alerty rządowe i niezweryfikowane zgłoszenia społeczności.
- **Sygnały SOS:** aktywacje przycisku paniki w czasie rzeczywistym od użytkowników potrzebujących natychmiastowej pomocy.

## 2.2 Model danych (podglądowo)

```c++
type VerificationLevel = 'OFFICIAL' | 'NGO_VERIFIED' | 'CROWDSOURCED' | 'UNVERIFIED';

type PointOfInterestType =
  | 'FIELD_HOSPITAL'
  | 'PHARMACY'
  | 'MINEFIELD'
  | 'UXO'
  | 'COMBAT_ZONE'
  | 'CHECKPOINT'
  | 'EVACUATION_CORRIDOR'
  | 'ASSEMBLY_POINT'
  | 'BOMB_SHELTER'
  | 'WATER_POINT'
  | 'SOS_BEACON';

type OperationalStatus = 'ACTIVE' | 'AT_CAPACITY' | 'DESTROYED' | 'UNKNOWN';

interface Coordinates {
  latitude: number;
  longitude: number;
}

interface PointOfInterest {
  id: string;
  type: PointOfInterestType;
  coordinates: Coordinates;
  status: OperationalStatus;
  verificationLevel: VerificationLevel;
  timestamp: string;
  expiresAt?: string;
  metadata: Record<string, string | number | boolean>;
}

interface EvacuationRoute {
  id: string;
  waypoints: Coordinates[];
  isOpen: boolean;
  safeHoursStart?: string;
  safeHoursEnd?: string;
  threatLevel: 'LOW' | 'MEDIUM' | 'HIGH';
}
```

## 2.3 Data Flow Diagram (DFD)

**Poziom 0 (kontekstowy)**

```mermaid
flowchart LR
    USER([Cywil / wolontariusz]) -->|zgłoszenia, SOS, zapytania| SYS[[System S.U.R.V.I.V.E]]
    NGO([NGO / służby]) -->|dane zweryfikowane| SYS
    SYS -->|mapa POI, alerty, trasy| USER
    SYS -->|raporty, statusy zasobów| NGO
    GPS([GPS - zakłócany]) -.->|opcjonalnie| SYS
```

**Poziom 1**

```mermaid
flowchart TB
    subgraph APP[Aplikacja Flutter]
        UI[1.0 UI / Mapa] --> VAL[2.0 Walidacja wejścia]
        VAL --> REPO[3.0 Repozytorium POI]
        REPO --> DB[(D1: SQLite lokalna)]
        REPO --> BLE[4.0 Moduł BLE / Meshtastic API]
    end
    subgraph NODE[Węzeł LoRa]
        BLE <--> FW[5.0 Firmware: kodek, kolejka, routing]
        FW --> FLASH[(D2: LittleFS: cache POI, whitelist)]
        FW --> POS[6.0 Moduł lokalizacji / ranging]
        FW <--> RADIO[7.0 Radio 868 MHz / SX1280]
    end
    RADIO <-->|mesh| OTHER([Inne węzły])
```

## 2.4 Persistent storage

Dane są przechowywane na dwóch poziomach. Najważniejszy jest poziom lokalny, bo zakłada się brak internetu.

|Poziom|Technologia|Zawartość|
|---|---|---|
|**Węzeł (firmware)**|LittleFS na flash / NVS|cache POI (ring buffer z wygasaniem po TTL), whitelist/blacklist, ostatnia pozycja|
|**Telefon**|SQLite (`drift`) + pliki kafelków OSM offline|pełna lokalna baza POI, historia wiadomości, ustawienia, kolejka do wysłania|

**Strategia synchronizacji:** _offline-first_. Rekordy mają `id` + `timestamp` + `version`, a konflikty rozwiązuje reguła „najnowszy wygrywa z uwzględnieniem poziomu weryfikacji" (`OFFICIAL` nadpisuje `CROWDSOURCED` niezależnie od czasu, chyba że wygasł TTL).

## 2.5 Diagram ERD

```mermaid
erDiagram
    USER ||--o{ POINT_OF_INTEREST : zglasza
    USER ||--o{ MESSAGE : wysyla
    USER ||--o{ SOS_EVENT : aktywuje
    NODE ||--o{ POINT_OF_INTEREST : przekazuje
    NODE ||--o{ RANGING_MEASUREMENT : "mierzony w"
    POINT_OF_INTEREST ||--o| RESOURCE_STATUS : opisuje
    EVACUATION_ROUTE ||--|{ ROUTE_WAYPOINT : zawiera
    EVACUATION_ROUTE }o--o{ POINT_OF_INTEREST : "laczy"

    USER {
        string id PK
        string display_name
        string role "CIVILIAN|VOLUNTEER|NGO|OFFICIAL"
        datetime created_at
    }
    NODE {
        string id PK
        string hw_type "ESP32"
        float last_lat
        float last_lon
        string position_source
        datetime position_updated_at
        int battery_pct
    }
    RANGING_MEASUREMENT {
        int id PK
        string from_node FK
        string to_node FK
        float distance_m
        float rssi
        datetime measured_at
    }
    POINT_OF_INTEREST {
        string id PK
        string type
        float latitude
        float longitude
        string status
        string verification_level
        datetime created_at
        datetime expires_at
        string reporter_id FK
        string metadata_json
    }
    RESOURCE_STATUS {
        string poi_id PK
        int capacity
        int occupied
        string critical_items_json
    }
    EVACUATION_ROUTE {
        string id PK
        boolean is_open
        string safe_hours_start
        string safe_hours_end
        string threat_level
    }
    ROUTE_WAYPOINT {
        int id PK
        string route_id FK
        int seq
        float latitude
        float longitude
    }
    MESSAGE {
        string id PK
        string sender_id FK
        string recipient_id
        string channel
        string body
        datetime sent_at
        string delivery_state
    }
    SOS_EVENT {
        string id PK
        string user_id FK
        float latitude
        float longitude
        string state "ACTIVE|ACKED|RESOLVED"
        datetime created_at
    }
```

## 2.6 Implementacja zapisu i odczytu danych

**Wzorzec repozytorium (Dart):**

```dart
abstract class PoiRepository {
  Future<void> upsert(PointOfInterest poi);
  Future<PointOfInterest?> getById(String id);
  Stream<List<PointOfInterest>> watchInBounds(LatLngBounds bounds, {Set<PoiType>? types});
  Future<int> purgeExpired(DateTime now);
}

class DriftPoiRepository implements PoiRepository {
  DriftPoiRepository(this._db);
  final AppDatabase _db;

  @override
  Future<void> upsert(PointOfInterest poi) async {
    final existing = await getById(poi.id);
    if (existing != null && !poi.shouldReplace(existing)) return; // reguła konfliktów
    await _db.into(_db.pois).insertOnConflictUpdate(poi.toCompanion());
  }

  @override
  Future<int> purgeExpired(DateTime now) =>
      (_db.delete(_db.pois)..where((t) => t.expiresAt.isSmallerThanValue(now))).go();
}
```

**Firmware (C++), zapis do cache na flash:**

- ring buffer rekordów o stałym rozmiarze w LittleFS,
- zapis z CRC16 i numerem sekwencji (odporność na zanik zasilania),
- okresowe czyszczenie rekordów po `expiresAt`.

## 2.7 Walidacja danych wejściowych

| Pole                           | Reguła                                                            | Działanie przy błędzie                                |
| ------------------------------ | ----------------------------------------------------------------- | ----------------------------------------------------- |
| `latitude`                     | −90 ≤ x ≤ 90, liczba skończona                                    | odrzucenie + log `WARN`                               |
| `longitude`                    | −180 ≤ x ≤ 180, liczba skończona                                  | odrzucenie + log `WARN`                               |
| `type`                         | wartość z enuma                                                   | odrzucenie (nieznany typ → `UNKNOWN`, nie propagować) |
| `status` / `verificationLevel` | wartość z enuma                                                   | obniżenie do `UNVERIFIED`                             |
| `timestamp`                    | nie dalej niż np. 10 min w przyszłość i nie starszy niż np. 7 dni | odrzucenie                                            |
| `expiresAt`                    | późniejszy niż `timestamp`, maks. np. 30 dni                      | przycięcie do maksimum                                |
| `metadata`                     | maks. liczba kluczy i długość wartości, brak znaków sterujących   | odrzucenie nadmiarowych pól                           |
| tekst wiadomości               | maks. długość (np. 200 znaków), normalizacja UTF-8                | obcięcie / odrzucenie                                 |
| pakiet radiowy                 | poprawny CRC, długość ≤ limit, wersja obsługiwana                 | odrzucenie bez parsowania dalej                       |
| dystans z ranging              | ≥ 0 i ≤ maks. zasięg radia                                        | odrzucenie pomiaru jako outlier                       |

Walidacja odbywa się **dwukrotnie**: w UI (szybka informacja zwrotna) oraz w warstwie domenowej/firmware (nie wolno ufać danym z eteru ani z aplikacji).

---

# 3. Testowanie

Plan testów obejmuje cztery poziomy.

## 3.1 Testy jednostkowe (bez zależności)

**Narzędzia:** Unity (firmware, kompilacja natywna na PC, bez sprzętu), `flutter_test` + `mocktail` (aplikacja). Każda jednostka testowana w izolacji, zależności zastąpione atrapami (mock).

|Jednostka|Scenariusz|Oczekiwany wynik|
|---|---|---|
|`Trilateration.solve`|3 węzły o znanych pozycjach, dokładne dystanse|pozycja zgodna z prawdziwą (błąd < 0,01 m)|
|`Trilateration.solve`|dystanse z szumem ±5 m|błąd pozycji w granicach tolerancji, zwrócony promień niepewności > 0|
|`NodeSelector.pick`|lista 6 węzłów o różnych kątach i dystansach|wybrane są węzły o najlepszym `score` (bez błędów zaokrągleń)|
|`NodeSelector.pick`|zestaw o bardzo niskim kącie (węzły niemal współliniowe)|niski `geometry score`, ostrzeżenie `LOW_CONFIDENCE`|
|`NodeSelector.pick`|zestaw o kącie bliskim 90°|najwyższy `geometry score`|
|`RangingMath.distance`|czasy reakcji 0 / typowe / bardzo duże|poprawne odległości, brak przepełnień (overflow), brak wartości ujemnych|
|`OutlierFilter`|seria pomiarów z jednym skrajnym|skrajny pomiar odrzucony (mediana + MAD)|
|`PoiCodec.encode/decode`|round-trip dla każdego typu POI|`decode(encode(x)) == x`, rozmiar ≤ 24 B|
|`PoiCodec.decode`|pakiet z błędnym CRC|wyjątek `CrcMismatch`, brak zmian stanu|
|`TtlPolicy.isExpired`|granice czasu (dokładnie TTL, TTL+1)|poprawny wynik na granicy|
|`TrustManager`|nadawca przekracza limit pakietów/min|węzeł oznaczony jako ignorowany|
|`TrustManager`|ręczne cofnięcie blokady|węzeł znów akceptowany|
|`PoiValidator`|współrzędne poza zakresem, NaN, nieznany typ|odrzucenie z odpowiednim kodem błędu|
|`ConflictResolver`|`OFFICIAL` vs `CROWDSOURCED`, nowszy i starszy|wygrywa wyższy poziom weryfikacji|

## 3.2 Testy komponentów (integracyjne)

|Komponenty|Scenariusz|Oczekiwany wynik|
|---|---|---|
|`PoiCodec` + `RadioQueue` + `Dedup`|wiele pakietów z duplikatami|tylko unikalne trafiają do nadawania|
|Aplikacja ↔ węzeł przez BLE (mock GATT)|wysłanie POI z aplikacji|pakiet w kolejce węzła, potwierdzenie w UI|
|`PoiRepository` + SQLite (in-memory)|upsert, odczyt w obszarze mapy, wygasanie po TTL|poprawne dane i brak wygasłych rekordów|
|`TrustManager` + `RadioRx`|węzeł-spamer wśród prawidłowych|spam ignorowany, pozostały ruch niezakłócony|
|Moduł mapy (`osm_flutter_plugin`) + repozytorium|dodanie POI|marker pojawia się na mapie, aktualizuje się strumień|

## 3.3 Testy wydajności (niefunkcjonalne)

|Metryka|Scenariusz|Cel / próg|
|---|---|---|
|Czas ranging + obliczenie pozycji|6 węzłów w zasięgu|pozycja w ≤ 5 s|
|Rozmiar pakietu|1000 losowych POI|średnio ≤ 24 B, maks. ≤ 100 B|
|Zużycie pamięci RAM / flash|pełny cache POI (np. 500 rekordów)|RAM w limicie ESP32, brak wycieków (heap przed/po)|
|Czas odczytu z bazy w aplikacji|10 000 POI, zapytanie po obszarze|≤ 100 ms (z indeksem przestrzennym)|
|Płynność mapy|2 000 markerów (klastrowanie)|≥ 30 FPS na średnim telefonie|

## 3.4 Testy akceptacyjne UAT (z użyciem UI)

Testy wykonują osoby spoza zespołu implementacyjnego (np. koledzy z roku, wolontariusze) według scenariuszy odpowiadających przypadkom użycia z sekcji 10. Sprzęt: 3–5 węzłów + 2–3 telefony.

|Scenariusz biznesowy|Kroki|Kryterium akceptacji|
|---|---|---|
|Ustalenie pozycji bez GPS|wyłączenie GPS, uruchomienie aplikacji, „Gdzie jestem?"|pozycja na mapie z promieniem niepewności w ≤ 10 s|
|Zgłoszenie pola minowego|wybór typu, wskazanie punktu, TTL, wysłanie|punkt widoczny na drugim telefonie w ≤ 30 s|
|Aktualizacja stanu szpitala polowego|koordynator zmienia miejsca z „ACTIVE" na „AT_CAPACITY"|zmiana widoczna u wszystkich użytkowników, ikona zmienia kolor|
|Planowanie ewakuacji|użytkownik wybiera trasę z korytarza humanitarnego, widzi godziny bezpieczne|trasa wyświetla się z poziomem zagrożenia i oknem czasowym|
|SOS|przytrzymanie przycisku SOS 3 s|alert u wszystkich w zasięgu, potwierdzenie (ACK) widoczne dla nadawcy|
|Zarządzanie zaufaniem|użytkownik blokuje węzeł-spamer|wiadomości od niego znikają, ruch normalny|

---

# 4. Bazy danych

Szczegółowe diagramy (DFD, ERD) i implementacja znajdują się w sekcji **2** (2.3–2.7). Podsumowanie:

- **Węzeł:** LittleFS/NVS (cache POI z TTL, whitelist), rekordy odporne na zanik zasilania.
- **Telefon:** SQLite przez `drift`, indeks po `(latitude, longitude)` i `expires_at`, kafelki map offline na karcie/pamięci.
- **Zasady:** offline-first, minimalizacja danych osobowych (anonimowe identyfikatory zamiast imion).
- **Walidacja:** podwójna (UI + warstwa domenowa/firmware), zgodnie z tabelą w 2.7.

---

# 5. UI/UX

## 5.1 Persony

|                         |**Maria, 34 l., cywil**|**Dr Marek, 45 l., lekarz w szpitalu polowym**|
|---|---|---|
| Cel                     |bezpieczne dotarcie do punktu ewakuacji|aktualizacja stanu miejsc i leków oraz wezwanie dostaw|
| Kontekst                |stres, słaba bateria, brak internetu|ręce zajęte, mało czasu, rękawice|
| Umiejętności techniczne |podstawowe|średnie|
| Urządzenie              |telefon + tanie urządzenie|telefon + tanie urządzenie|
| Największy lęk          |wejście na minę lub w strefę walk|zbyt późna informacja o brakach leków|

## 5.2 User Journey (cel główny dla każdej persony)

### Maria: „Dotrzeć bezpiecznie do punktu ewakuacji"

|Etap|Działanie|Touch point (ekran mockupu)|Pain point|Opportunity|
|---|---|---|---|---|
|1. Uruchomienie|włącza urządzenie i aplikację|S2 Status połączenia|niepewność, czy sieć działa|wyraźny wskaźnik „połączono z X węzłami"|
|2. Pozycja|patrzy, gdzie jest|S3 Mapa + okrąg niepewności|brak GPS, nie wie, czy ufać pozycji|jasny komunikat jakości pozycji (zielony/żółty/czerwony)|
|3. Zagrożenia|sprawdza zagrożenia w pobliżu|S3 warstwy + S4 Lista zagrożeń|zbyt dużo informacji naraz|filtr „tylko krytyczne", sortowanie wg odległości|
|4. Trasa|wybiera korytarz humanitarny|S5 Szczegóły trasy|niewiadomo, czy trasa jest otwarta|godziny bezpieczne, poziom zagrożenia, znacznik świeżości|

### Dr Marek: „Zaktualizować stan szpitala polowego"

|Etap|Działanie|Touch point|Pain point|Opportunity|
|---|---|---|---|---|
|1. Edycja|zmienia liczbę miejsc, leki|S9 Edycja zasobu|wpisywanie na małym ekranie|szablony, przyciski +/−|
|2. Wysłanie|zatwierdza aktualizację|S10 Potwierdzenie wysyłki|brak wiedzy, czy dotarło|statusy: w kolejce / wysłano / potwierdzono|

## 5.3 User Flows

**Przepływ główny: zgłoszenie zagrożenia (z sukcesami, błędami i stanami systemu)**

```mermaid
flowchart TD
    A(["Start: ekran mapy S3"]) --> B["Przycisk Zgłoś -> S15 Wybór typu"]
    B --> C["S16 Wskaż punkt: aktualna pozycja lub mapa"]
    C --> D{"Pozycja dostępna?"}
    D -- tak --> E["S17 Szczegóły: status, TTL, notatka"]
    D -- brak pozycji --> D1["Stan błędu: Brak pozycji -> ręczne wskazanie na mapie"]
    D1 --> E
    E --> F{"Walidacja pól"}
    F -- błąd --> F1["Stan błędu: komunikat przy polu"]
    F1 --> E
    F -- ok --> G["Stan ładowania: Wysyłanie..."]
    G --> H{"Połączenie z węzłem?"}
    H -- brak BLE --> H1["Stan błędu: Brak połączenia z urządzeniem -> zapis w kolejce"]
    H1 --> J
    H -- ok --> I{"Węzeł przyjął pakiet?"}
    I -- tak --> J["S10 Sukces: w kolejce / wysłano"]
    I -- timeout --> I1["Ponów 3x -> komunikat Spróbuj ponownie"]
    I1 --> G
    J --> K{"Potwierdzenie z sieci?"}
    K -- tak --> L["Status Potwierdzono"]
    K -- brak --> M["Status Wysłano, brak potwierdzenia"]
    L --> N(["Koniec"])
    M --> N
```

**Pozostałe przepływy do narysowania w Figma (po jednym diagramie):**

1. Ustalanie pozycji bez GPS (sukces, 2 węzły = niska pewność, brak węzłów).
2. SOS (przytrzymanie -> odliczanie 3 s -> wysyłka -> ACK; anulowanie; brak sieci = ponawianie).

**Stany systemu (dla każdego ekranu):**

|Stan|Zachowanie UI|
|---|---|
|Ładowanie|szkielet (skeleton) + spinner, brak blokady mapy|
|Pusty|„Brak zgłoszeń w pobliżu" + przycisk „Zgłoś"|
|Błąd|czytelny komunikat, kod, przycisk „Spróbuj ponownie"|
|Offline|baner „Brak internetu. Działa tryb mesh"|
|Niska bateria|baner + automatyczne oszczędzanie|

**Powiązanie kroków z mockupami (lista ekranów):** S2 Status połączenia, S3 Mapa, S4 Lista zagrożeń, S5 Szczegóły trasy, S9 Edycja zasobu, S10 Potwierdzenie wysyłki, S15 Wybór typu, S16 Wskaż punkt, S17 Szczegóły zgłoszenia, S19 SOS, S20 Zaufane węzły.

## 5.4 High Fidelity Mockups + style

Mockupy do wykonania w **Figmie**. Ważny kontrast i ekstremalna czytelność!

---

# 6. Obsługa błędów (errors + exceptions)

## 6.1 Logowanie

- **Poziomy:** `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL`.
- **Aplikacja:** pakiet `logger`, zapis do pliku z rotacją, eksport do wysłania zespołowi.
- **Prywatność:** w logach nie zapisujemy pozycji użytkowników z dokładnością < 100 m ani treści wiadomości; identyfikatory są skrócone.
- **Kody błędów (przykład):** `E1001 CRC_MISMATCH`, `E1002 INVALID_COORDINATES`, `E2001 RANGING_TIMEOUT`, `E2002 INSUFFICIENT_ANCHORS`, `E3001 BLE_DISCONNECTED`, `E5001 STORAGE_FULL`.

## 6.2 Wyjątki

| Warstwa          | Podejście                                                                                                                                                                                                                                                        |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Firmware (C++)   | brak wyjątków (`-fno-exceptions` na ESP32); używamy wartości zwrotnych `Result<T, Error>` / `std::optional` i kodów błędów, `assert` tylko dla błędów programisty; watchdog (WDT) restartuje przy zawieszeniu                                                    |
| Aplikacja (Dart) | własna hierarchia: `AppException` -> `ValidationException`, `RadioException`, `StorageException`, `SecurityException`; przechwytywanie w warstwie repozytorium i mapowanie na stany UI (`AsyncValue.error`); globalny `FlutterError.onError` + `runZonedGuarded` |
| Zasady           | nigdy nie „połykamy" wyjątków bez logu; komunikaty użytkownika są zrozumiałe, a szczegóły techniczne tylko w logu                                                                                                                                                |
| Odporność        | ponawianie z backoffem (ranging, wysyłka), degradacja funkcji (np. brak ranging -> ostatnia znana pozycja z ostrzeżeniem), bezpieczny stan po restarcie                                                                                                          |

## 6.3 Alerty

|Alert|Warunek|Odbiorca|Działanie|
|---|---|---|---|
|`SPAM_NODE_BLOCKED`|przekroczony limit pakietów|użytkownik|automatyczna blokada + opcja cofnięcia|
|`POSITION_LOW_CONFIDENCE`|tylko 2 węzły lub zła geometria|użytkownik|ostrzeżenie przy pozycji|
|`SOS_RECEIVED`|odebrany pakiet SOS|wszyscy w zasięgu|alarm dźwiękowy/wibracje, wskazanie lokalizacji|

Alerty mają priorytety (krytyczny / ostrzeżenie / informacja), a krytyczne wymagają potwierdzenia przez użytkownika.

---

# 7. Zabezpieczenia

## 7.1 Model zagrożeń

|Zagrożenie|Środek zaradczy|
|---|---|
|Zakłócanie radiowe (jamming)|LoRa CSS 868 MHz|
|Fałszywe dane (dezinformacja, np. fałszywy „bezpieczny korytarz")|poziomy weryfikacji|
|Spoofing pozycji, replay|znaczniki czasu + numery sekwencji, okno ważności, deduplikacja|
|Spam / DoS|rate limiting, automatyczne ignorowanie węzłów, kolejka priorytetowa|
|Podsłuch wiadomości prywatnych|szyfrowanie AES-256 (kanały Meshtastic) + klucze publiczne dla wiadomości prywatnych (PKC)|
|Namierzanie użytkowników|minimalizacja metadanych, anonimowe ID, opcjonalne zmniejszenie dokładności pozycji|
|Złośliwe pakiety (przepełnienia)|walidacja, limity rozmiarów|

---

# 8. Business Model Canvas

| Blok BMC                                               | Zawartość                                                                                                                                                                    |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Key Partners** (Kluczowi partnerzy)                  | NGO i organizacje humanitarne, społeczność Meshtastic, OpenStreetMap, producenci sprzętu                                                                                     |
| **Key Activities** (Kluczowe działania)                | rozwój firmware i aplikacji, testy terenowe, szkolenia, budowa sieci węzłów                                                                                                  |
| **Key Resources** (Kluczowe zasoby)                    | zespół, sprzęt (węzły), mapy OSM                                                                                                                                             |
| **Value Propositions** (Propozycja wartości)           | „Mapa i łączność, które działają, kiedy wszystko inne przestaje: tanio, bez internetu, bez GPS, z wiarygodnymi danymi."                                                      |
| **Customer Relationships** (Relacje z klientami)       | _do uzupełnienia_                                                                                                                                                            |
| **Channels** (Kanały)                                  | _do uzupełnienia_                                                                                                                                                            |
| **Customer Segments** (Segmenty klientów)              | cywile w strefach konfliktu, organizacje humanitarne (NGO, Czerwony Krzyż), służby ratunkowe i medyczne, władze lokalne / obrona cywilna, darczyńcy i instytucje wspierające |
| **Cost Structure** (Struktura kosztów)                 | komponenty (ESP32, SX1280), prototypowanie, certyfikacja radiowa (868 MHz), utrzymanie                                                                                       |
| **Revenue Streams** (Źródła przychodów / finansowania) | granty (programy wsparcia humanitarnego), darowizny, sprzedaż zestawów po koszcie, wsparcie instytucjonalne; oprogramowanie otwarte                                          |

---

# 9. Omówienie 5 przypadków użycia (User Stories)

> **US-1** Ustalenie pozycji bez GPS · **US-2** Zgłoszenie zagrożenia · **US-3** Aktualizacja stanu szpitala polowego · **US-4** Ewakuacja i SOS · **US-5** Zarządzanie zaufanymi węzłami

## Ustalenie pozycji bez GPS

| Pole                         | Opis                                                                                                                                                                                                                                                |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Aktor**                    | cywil / wolontariusz                                                                                                                                                                                                                                |
| **Cel**                      | poznanie własnej pozycji mimo zakłócania GPS                                                                                                                                                                                                        |
| **Warunki wstępne**          | w zasięgu bezpośrednim są co najmniej 2–3 węzły z zapamiętaną pozycją                                                                                                                                                                               |
| **Scenariusz główny**        | 1) Użytkownik otwiera mapę. 2) Aplikacja wykrywa brak GPS i uruchamia procedurę. 3) Urządzenie pyta węzły o koordynaty. 4) Mierzy dystanse (ranging). 5) Wybiera najlepsze węzły. 6) Oblicza pozycję. 7) Mapa pokazuje punkt i promień niepewności. |
| **Scenariusze alternatywne** | tylko 2 węzły -> pozycja z niską pewnością; brak węzłów -> ostatnia znana pozycja + ostrzeżenie; zła geometria -> sugestia zmiany miejsca                                                                                                           |
| **Warunki końcowe**          | pozycja i jakość zapisane w stanie urządzenia                                                                                                                                                                                                       |

## Zgłoszenie zagrożenia (np. pole minowe)

| Pole                         | Opis                                                                                                                                                                                                                                                   |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Aktor**                    | cywil, wolontariusz                                                                                                                                                                                                                                    |
| **Cel**                      | ostrzeżenie innych o zagrożeniu                                                                                                                                                                                                                        |
| **Warunki wstępne**          | aplikacja połączona z węzłem (BLE), znana pozycja (lub wskazana ręcznie)                                                                                                                                                                               |
| **Scenariusz główny**        | 1) „Zgłoś" -> wybór typu `MINEFIELD`. 2) Wskazanie punktu/obszaru. 3) Ustawienie TTL i notatki. 4) Walidacja. 5) Zapis lokalny. 6) Kodowanie do pakietu i wysłanie do mesh. 7) Inne urządzenia odbierają, walidują i pokazują marker (`CROWDSOURCED`). |
| **Scenariusze alternatywne** | błędne dane -> komunikat; brak BLE -> zapis w kolejce, wysyłka później; pakiet odrzucony przez węzły (spam) -> informacja o limicie                                                                                                                    |
| **Warunki końcowe**          | zagrożenie widoczne w sieci do wygaśnięcia TTL lub weryfikacji przez NGO                                                                                                                                                                               |

## Aktualizacja stanu szpitala polowego

| Pole                         | Opis                                                                                                                                             |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Aktor**                    | lekarz / koordynator NGO                                                                                                                         |
| **Cel**                      | aktualne dane o miejscach i lekach                                                                                                               |
| **Scenariusz główny**        | 1) Odblokowanie (PIN). 2) Edycja zasobu: miejsca, leki. 3) Wysłanie jako `NGO_VERIFIED`. 4) Mapa aktualizuje ikonę i status (np. `AT_CAPACITY`). |
| **Scenariusze alternatywne** | brak potwierdzenia -> ponawianie                                                                                                                 |
| **Warunki końcowe**          | zaktualizowany stan zasobu w całej sieci                                                                                                         |

## Ewakuacja i wezwanie pomocy (SOS)

| Pole                          | Opis                                                                                                                                                                                                                    |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Aktor**                     | cywil (ewakuowany), służby/wolontariusze (odbiorcy SOS)                                                                                                                                                                 |
| **Cel**                       | bezpieczne dotarcie do punktu ewakuacji lub otrzymanie pilnej pomocy                                                                                                                                                    |
| **Warunki wstępne**           | zsynchronizowane dane o korytarzach, punktach zbiórki i zagrożeniach                                                                                                                                                    |
| **Scenariusz główny (trasa)** | 1) Użytkownik otwiera „Ewakuacja". 2) Widzi korytarze humanitarne (godziny bezpieczne, poziom zagrożenia). 3) Wybiera trasę omijającą zagrożenia. 4) Podąża za wskazówkami, alerty ostrzegają o nowych zagrożeniach.    |
| **Scenariusz główny (SOS)**   | 1) Przytrzymanie przycisku SOS 3 s. 2) Wysłanie pakietu `SOS_BEACON` o najwyższym priorytecie z pozycją. 3) Węzły w sieci przekazują dalej. 4) Odbiorca potwierdza (ACK). 5) Nadawca widzi status „Pomoc powiadomiona". |
| **Scenariusze alternatywne**  | trasa zamknięta/wygasła -> propozycja objazdu; brak potwierdzenia SOS -> powtarzanie z backoffem                                                                                                                        |
| **Warunki końcowe**           | użytkownik dotarł do punktu ewakuacji lub SOS potwierdzony                                                                                                                                                              |

## Zarządzanie zaufanymi węzłami (US-5)

**Historia użytkownika:** _Jako cywil lub wolontariusz chcę wskazywać węzły zaufane i blokować węzły zakłócające, aby fałszywe lub spamujące dane nie zalewały mojej mapy ani nie zajmowały pasma radiowego._

| Pole                         | Opis                                                                                                                                                                                                                                                                                                  |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Aktor**                    | cywil / wolontariusz / koordynator NGO                                                                                                                                                                                                                                                                |
| **Cel**                      | kontrola nad tym, od których węzłów przyjmowane są dane                                                                                                                                                                                                                                               |
| **Warunki wstępne**          | aplikacja połączona z węzłem (BLE); w pobliżu lub w historii są co najmniej 2 inne węzły                                                                                                                                                                                                              |
| **Scenariusz główny**        | 1) Użytkownik otwiera ekran S20 „Zaufane węzły". 2) Widzi listę węzłów z krótkim ID, poziomem zaufania, liczbą pakietów/min i czasem ostatniego kontaktu. 3) Oznacza węzeł jako zaufany (whitelist) lub zablokowany (blacklist). 4) Zmiana zapisuje się lokalnie (LittleFS na węźle, SQLite w aplikacji). 5) Dane od zablokowanego węzła znikają z mapy, a nowe pakiety są odrzucane przed parsowaniem. |
| **Scenariusze alternatywne** | węzeł przekroczył próg spamu (> N pakietów/min) -> automatyczna blokada + alert `SPAM_NODE_BLOCKED` z opcją cofnięcia; użytkownik cofa blokadę -> węzeł znów akceptowany; brak BLE -> zmiana w kolejce, zastosowana po połączeniu                                                                    |
| **Warunki końcowe**          | listy zaufania zsynchronizowane między aplikacją a węzłem; ruch od zablokowanych węzłów nie trafia do kolejki ani na mapę                                                                                                                                                                              |

**Kryteria akceptacji (Given/When/Then):**

- _Given_ węzeł wysyła > N pakietów/min, _When_ próg zostaje przekroczony, _Then_ węzeł jest ignorowany, a użytkownik dostaje alert z przyciskiem „Cofnij".
- _Given_ zablokowany węzeł, _When_ użytkownik cofa blokadę, _Then_ kolejne pakiety są przyjmowane i walidowane jak zwykle.
- _Given_ restart urządzenia, _When_ węzeł się uruchamia, _Then_ whitelist i blacklist są odtworzone z pamięci trwałej.

---

# 10. Diagramy przypadków użycia (UML Use Case)

Diagramy w notacji UML, zapisane w **PlantUML** (UML Use Case nie ma natywnego odpowiednika w Mermaid). Zakres jest taki sam jak historii US-1...US-5 z sekcji 9. Relacje `<<include>>` oznaczają obowiązkowy fragment zachowania, a `<<extend>>` zachowanie opcjonalne lub warunkowe.

## 10.1 Diagram ogólny systemu

```plantuml
@startuml
left to right direction
skinparam packageStyle rectangle
skinparam actorStyle awesome

actor "Cywil" as Civ
actor "Wolontariusz" as Vol
actor "Lekarz / koordynator NGO" as Doc
actor "Węzeł LoRa (mesh)" as Node <<system>>
actor "Odbiorca SOS (służby)" as Rescuer

rectangle "System S.U.R.V.I.V.E" {
  usecase "UC1: Ustal pozycję bez GPS\n(US-1)" as UC1
  usecase "UC2: Zgłoś zagrożenie\n(US-2)" as UC2
  usecase "UC3: Zaktualizuj stan\nszpitala polowego\n(US-3)" as UC3
  usecase "UC4: Zaplanuj ewakuację\n(US-4)" as UC4
  usecase "UC5: Wyślij SOS\n(US-4)" as UC5
  usecase "UC6: Zarządzaj zaufanymi\nwęzłami (US-5)" as UC6

  usecase "Wykonaj ranging\n(SX1280)" as UCr
  usecase "Zakoduj i wyślij pakiet\n(PoiCodec)" as UCs
  usecase "Zwaliduj dane" as UCv
  usecase "Zapisz w kolejce\n(brak BLE)" as UCq
  usecase "Przeglądaj mapę POI" as UCm
  usecase "Odblokuj PIN" as UCp
  usecase "Potwierdź SOS (ACK)" as UCa
  usecase "Zablokuj węzeł\nautomatycznie (spam)" as UCb
}

Civ --> UC1
Civ --> UC2
Civ --> UC4
Civ --> UC5
Civ --> UC6
Vol --> UC2
Vol --> UC6
Doc --> UC3
Doc --> UC6
Rescuer --> UCa
Node --> UCr
Node --> UCs

UC1 ..> UCr : <<include>>
UC2 ..> UCv : <<include>>
UC2 ..> UCs : <<include>>
UC3 ..> UCv : <<include>>
UC3 ..> UCs : <<include>>
UC3 ..> UCp : <<include>>
UC4 ..> UCm : <<include>>
UC5 ..> UCs : <<include>>
UCq ..> UC2 : <<extend>>
UCq ..> UC3 : <<extend>>
UCa ..> UC5 : <<extend>>
UCb ..> UC6 : <<extend>>
@enduml
```

## 10.2 Diagramy per user story

**US-1: Ustalenie pozycji bez GPS**

```plantuml
@startuml
left to right direction
actor "Cywil / wolontariusz" as U
actor "Węzeł kotwiczący (A, B, C)" as N <<system>>
rectangle "US-1" {
  usecase "Ustal pozycję bez GPS" as A
  usecase "Rozgłoś POSITION_REQUEST" as B
  usecase "Zmierz dystanse (ranging)" as C
  usecase "Odfiltruj outliery (mediana + MAD)" as D
  usecase "Wybierz najlepsze 2/3 węzły" as E
  usecase "Oblicz pozycję (trilateracja)" as F
  usecase "Pokaż okrąg niepewności" as G
  usecase "Użyj ostatniej znanej pozycji" as H
  usecase "Oznacz LOW_CONFIDENCE\n(tylko 2 węzły)" as I
}
U --> A
N --> B
N --> C
A ..> B : <<include>>
A ..> C : <<include>>
A ..> D : <<include>>
A ..> E : <<include>>
A ..> F : <<include>>
A ..> G : <<include>>
H ..> A : <<extend>>\n[brak węzłów]
I ..> A : <<extend>>\n[2 węzły]
@enduml
```

**US-2: Zgłoszenie zagrożenia**

```plantuml
@startuml
left to right direction
actor "Cywil / wolontariusz" as U
actor "Węzeł LoRa" as N <<system>>
rectangle "US-2" {
  usecase "Zgłoś zagrożenie" as A
  usecase "Wybierz typ POI" as B
  usecase "Wskaż punkt / obszar" as C
  usecase "Ustaw TTL i notatkę" as D
  usecase "Zwaliduj pola" as E
  usecase "Zapisz lokalnie" as F
  usecase "Zakoduj i wyślij do mesh" as G
  usecase "Wskaż punkt ręcznie na mapie" as H
  usecase "Zakolejkuj (brak BLE)" as I
  usecase "Ponów wysyłkę (backoff)" as J
}
U --> A
N --> G
A ..> B : <<include>>
A ..> C : <<include>>
A ..> D : <<include>>
A ..> E : <<include>>
A ..> F : <<include>>
A ..> G : <<include>>
H ..> C : <<extend>>\n[brak pozycji]
I ..> G : <<extend>>\n[brak BLE]
J ..> G : <<extend>>\n[timeout]
@enduml
```

**US-3: Aktualizacja stanu szpitala polowego**

```plantuml
@startuml
left to right direction
actor "Lekarz / koordynator NGO" as D
actor "Użytkownicy w sieci" as V
rectangle "US-3" {
  usecase "Zaktualizuj stan zasobu" as A
  usecase "Odblokuj PIN" as B
  usecase "Edytuj miejsca i leki" as C
  usecase "Wyślij jako NGO_VERIFIED" as E
  usecase "Pokaż status wysyłki\n(w kolejce / wysłano / potwierdzono)" as F
  usecase "Zaktualizuj ikonę i status na mapie" as G
  usecase "Ponów wysyłkę" as H
}
D --> A
V --> G
A ..> B : <<include>>
A ..> C : <<include>>
A ..> E : <<include>>
A ..> F : <<include>>
G ..> E : <<extend>>
H ..> E : <<extend>>\n[brak potwierdzenia]
@enduml
```

**US-4: Ewakuacja i SOS**

```plantuml
@startuml
left to right direction
actor "Cywil (ewakuowany)" as C
actor "Służby / wolontariusze" as R
rectangle "US-4" {
  usecase "Zaplanuj ewakuację" as A
  usecase "Przeglądaj korytarze humanitarne" as B
  usecase "Wybierz trasę\nomijającą zagrożenia" as D
  usecase "Otrzymuj alerty o nowych zagrożeniach" as E
  usecase "Zaproponuj objazd" as F
  usecase "Wyślij SOS (przytrzymanie 3 s)" as G
  usecase "Nadaj SOS_BEACON\n(najwyższy priorytet)" as H
  usecase "Potwierdź SOS (ACK)" as I
  usecase "Powtarzaj SOS z backoffem" as J
  usecase "Anuluj SOS" as K
}
C --> A
C --> G
R --> I
A ..> B : <<include>>
A ..> D : <<include>>
A ..> E : <<include>>
F ..> A : <<extend>>\n[trasa zamknięta / wygasła]
G ..> H : <<include>>
I ..> G : <<extend>>
J ..> G : <<extend>>\n[brak ACK]
K ..> G : <<extend>>\n[w trakcie odliczania]
@enduml
```

**US-5: Zarządzanie zaufanymi węzłami**

```plantuml
@startuml
left to right direction
actor "Użytkownik" as U
actor "Węzeł LoRa" as N <<system>>
rectangle "US-5" {
  usecase "Zarządzaj zaufanymi węzłami" as A
  usecase "Przeglądaj listę węzłów" as B
  usecase "Dodaj do whitelisty" as C
  usecase "Dodaj do blacklisty" as D
  usecase "Cofnij blokadę" as E
  usecase "Zablokuj automatycznie\n(próg spamu)" as F
  usecase "Pokaż alert SPAM_NODE_BLOCKED" as G
  usecase "Zapisz listy w pamięci trwałej" as H
}
U --> A
N --> F
A ..> B : <<include>>
A ..> H : <<include>>
C ..> A : <<extend>>
D ..> A : <<extend>>
E ..> A : <<extend>>
F ..> G : <<include>>
G ..> E : <<extend>>
@enduml
```

---

# 11. Diagram wymagań SysML i klasyfikacja ISO/IEC 25002 (SQuaRE)

## 11.1 Klasyfikacja wymagań

Rodzina **ISO/IEC 25000 (SQuaRE)** porządkuje jakość oprogramowania. **ISO/IEC 25002** opisuje model jakości i sposób jego użycia, a konkretne charakterystyki jakości produktu definiuje **ISO/IEC 25010**. Metryki bierzemy z **ISO/IEC 25023**. Wymagania dzielimy na:

- **FR** (funkcjonalne): _co_ system robi, czyli charakterystyka _Functional suitability_ (kompletność, poprawność, adekwatność funkcjonalna).
- **NFR** (niefunkcjonalne): _jak dobrze_ to robi, czyli pozostałe charakterystyki: _Performance efficiency, Reliability, Security, Usability, Compatibility, Maintainability, Portability_ oraz _Safety_ (w nowszej edycji 25010).

## 11.2 Diagram wymagań (SysML Requirements Diagram)

Diagram w Mermaid (`requirementDiagram`) odwzorowuje SysML: stereotypy wymagań, relacje `contains`, `derives`, `refines`, `satisfies`, `verifies`. Każde NFR ma przypisaną metrykę jako element typu `metric` i relację `verifies`.

```mermaid
requirementDiagram

    requirement SYS_REQ {
        id: SYS
        text: "System zapewnia lacznosc i mape zagrozen bez GPS i internetu"
        risk: high
        verifymethod: demonstration
    }

    functionalRequirement FR1_Position {
        id: FR1
        text: "Ustalanie pozycji bez GPS metoda ranging i trilateracji (US-1)"
        risk: high
        verifymethod: test
    }
    functionalRequirement FR2_Report {
        id: FR2
        text: "Zglaszanie zagrozen z TTL i poziomem weryfikacji (US-2)"
        risk: medium
        verifymethod: test
    }
    functionalRequirement FR3_Resource {
        id: FR3
        text: "Aktualizacja stanu zasobow medycznych po odblokowaniu PIN (US-3)"
        risk: medium
        verifymethod: test
    }
    functionalRequirement FR4_Evac {
        id: FR4
        text: "Wyswietlanie korytarzy i planowanie trasy ewakuacji (US-4)"
        risk: medium
        verifymethod: demonstration
    }
    functionalRequirement FR5_SOS {
        id: FR5
        text: "Wysylanie SOS z potwierdzeniem ACK i ponawianiem (US-4)"
        risk: high
        verifymethod: test
    }
    functionalRequirement FR6_Trust {
        id: FR6
        text: "Zarzadzanie whitelista i blacklista oraz auto-blokada spamu (US-5)"
        risk: medium
        verifymethod: test
    }

    performanceRequirement NFR_Perf {
        id: NFR1
        text: "Wydajnosc: pozycja w 5 s, pakiet POI max 24 B (sr.), mapa 30 FPS"
        risk: medium
        verifymethod: test
    }
    requirement NFR_Avail {
        id: NFR2
        text: "Niezawodnosc - dostepnosc: wezel dziala co najmniej 99 procent czasu"
        risk: high
        verifymethod: analysis
    }
    requirement NFR_Fault {
        id: NFR3
        text: "Niezawodnosc - odtwarzalnosc: po restarcie MTTR do 30 s, brak utraty cache"
        risk: high
        verifymethod: test
    }
    requirement NFR_Sec {
        id: NFR4
        text: "Bezpieczenstwo: AES-256, PKC, CRC, rate limiting, odpornosc na jamming"
        risk: high
        verifymethod: test
    }
    requirement NFR_Use {
        id: NFR5
        text: "Uzytecznosc: SOS w 3 s, wysoki kontrast, zadanie bez przeszkolenia"
        risk: medium
        verifymethod: demonstration
    }
    requirement NFR_Maint {
        id: NFR6
        text: "Latwosc utrzymania: pokrycie testami jednostkowymi min 80 procent"
        risk: low
        verifymethod: analysis
    }
    designConstraint NFR_Port {
        id: NFR7
        text: "Przenosnosc: firmware ESP32 (Meshtastic), aplikacja Android i iOS (Flutter)"
        risk: low
        verifymethod: inspection
    }

    element M_Avail {
        type: "metryka: Availability = MTBF / (MTBF + MTTR)"
        docref: "ISO/IEC 25023"
    }
    element M_MTTR {
        type: "metryka: MTTR - sredni czas naprawy / restartu"
        docref: "ISO/IEC 25023"
    }
    element M_MTBF {
        type: "metryka: MTBF - sredni czas miedzy awariami"
        docref: "ISO/IEC 25023"
    }
    element M_Time {
        type: "metryka: czas odpowiedzi, przepustowosc, FPS"
        docref: "ISO/IEC 25023"
    }
    element M_Sec {
        type: "metryka: odsetek odrzuconych pakietow z blednym CRC, liczba udanych ataków w testach"
        docref: "ISO/IEC 25023"
    }
    element M_Task {
        type: "metryka: czas i skutecznosc zadania, wynik SUS"
        docref: "ISO/IEC 25023"
    }
    element M_Cov {
        type: "metryka: pokrycie testami, zlozonosc cyklomatyczna"
        docref: "ISO/IEC 25023"
    }

    SYS_REQ - contains -> FR1_Position
    SYS_REQ - contains -> FR2_Report
    SYS_REQ - contains -> FR3_Resource
    SYS_REQ - contains -> FR4_Evac
    SYS_REQ - contains -> FR5_SOS
    SYS_REQ - contains -> FR6_Trust
    SYS_REQ - contains -> NFR_Perf
    SYS_REQ - contains -> NFR_Avail
    SYS_REQ - contains -> NFR_Fault
    SYS_REQ - contains -> NFR_Sec
    SYS_REQ - contains -> NFR_Use
    SYS_REQ - contains -> NFR_Maint
    SYS_REQ - contains -> NFR_Port

    NFR_Fault - derives -> NFR_Avail
    NFR_Perf - refines -> FR1_Position
    NFR_Sec - refines -> FR6_Trust
    NFR_Use - refines -> FR5_SOS

    M_Avail - satisfies -> NFR_Avail
    M_MTBF - satisfies -> NFR_Avail
    M_MTTR - satisfies -> NFR_Fault
    M_Time - satisfies -> NFR_Perf
    M_Sec - satisfies -> NFR_Sec
    M_Task - satisfies -> NFR_Use
    M_Cov - satisfies -> NFR_Maint
```

> Uwaga: w Mermaid relacja `satisfies` jest użyta do powiązania metryki z wymaganiem. Jeśli wymagana jest ścisła SysML-owa semantyka (np. w Papyrus lub Cameo), metrykę modeluje się jako `Block` z wartością (`ValueProperty`), a wymaganie weryfikuje się relacją `verify` z `TestCase`.

## 11.3 Tabela wymagań z metrykami i celami

**Wymagania funkcjonalne (Functional suitability)**

| ID  | Wymaganie                                                              | Story | Metoda weryfikacji | Metryka (ISO/IEC 25023)                                 |
| --- | ---------------------------------------------------------------------- | ----- | ------------------ | ------------------------------------------------------- |
| FR1 | Ustalanie pozycji bez GPS (ranging, trilateracja, promień niepewności) | US-1  | test               | Functional correctness: błąd pozycji < 15 m (mediana)   |
| FR2 | Zgłoszenie zagrożenia z TTL i poziomem weryfikacji                     | US-2  | test               | Functional completeness: 100% typów POI obsłużonych     |
| FR3 | Aktualizacja stanu zasobu po PIN                                       | US-3  | test               | Functional completeness: 100% pól edytowalnych          |
| FR4 | Korytarze humanitarne i trasa z godzinami bezpiecznymi                 | US-4  | demonstracja       | Functional appropriateness: ukończenie zadania ≥ 90%    |
| FR5 | SOS z ACK i ponawianiem                                                | US-4  | test               | Functional correctness: ACK ≥ 95% w zasięgu             |
| FR6 | Whitelist, blacklist, auto-blokada spamu                               | US-5  | test               | Functional correctness: 0 pakietów z blacklisty na mapie |

**Wymagania niefunkcjonalne (NFR)**

| ID   | Charakterystyka ISO/IEC 25010 | Podcharakterystyka        | Wymaganie                                          | Metryka                                       | Cel / próg                                      |
| ---- | ----------------------------- | ------------------------- | -------------------------------------------------- | --------------------------------------------- | ----------------------------------------------- |
| NFR1 | Performance efficiency        | Time behaviour            | Pozycja i dane muszą być dostępne szybko           | Czas ranging + obliczenia; czas dotarcia POI  | ≤ 5 s (6 węzłów); POI u drugiego telefonu ≤ 30 s |
| NFR1 | Performance efficiency        | Resource utilization      | Mały pakiet i bezpieczne zużycie pamięci           | Średni rozmiar pakietu; RAM/flash             | ≤ 24 B (maks. 100 B); brak wycieków heap         |
| NFR2 | Reliability                   | Availability              | Węzeł jest dostępny w sieci                        | **Availability = MTBF / (MTBF + MTTR)**       | ≥ 99% (cel dla węzła zasilanego z baterii/PV)    |
| NFR2 | Reliability                   | Maturity                  | Rzadkie awarie                                     | **MTBF** (średni czas między awariami)        | ≥ 500 h pracy ciągłej w testach                  |
| NFR3 | Reliability                   | Recoverability            | Szybki powrót po awarii i zanikach zasilania       | **MTTR** (średni czas naprawy / restartu)     | ≤ 30 s do pełnej sprawności; 0 utraconych rekordów (CRC + sekwencje) |
| NFR3 | Reliability                   | Fault tolerance           | Degradacja zamiast awarii                          | Odsetek funkcji działających przy awarii radia | brak ranging → ostatnia pozycja z ostrzeżeniem   |
| NFR4 | Security                      | Confidentiality, Integrity | Szyfrowanie, kontrola integralności, anty-replay   | Odsetek pakietów odrzuconych (zły CRC/replay); udane ataki w pentestach | 100% odrzuceń; 0 udanych ataków w scenariuszach |
| NFR4 | Security                      | Resistance (jamming)      | Odporność na zakłócenia                            | Packet Delivery Ratio pod zakłócaniem         | ≥ 80% PDR przy zadanym SNR                       |
| NFR5 | Usability                     | Operability               | SOS łatwy do uruchomienia w stresie                | Czas uruchomienia SOS; wynik SUS              | ≤ 3 s (przytrzymanie); SUS ≥ 80                  |
| NFR5 | Usability                     | Accessibility             | Wysoki kontrast, duże elementy (rękawice)          | Kontrast WCAG; rozmiar celu dotykowego        | ≥ 7:1 (AAA); ≥ 48 dp                             |
| NFR6 | Maintainability               | Testability               | Kod pokryty testami                                | Pokrycie linii / gałęzi                       | ≥ 80% (logika domenowa)                          |
| NFR7 | Portability / Compatibility   | Adaptability, Interoperability | Zgodność z Meshtastic i platformami mobilnymi | Liczba platform zgodnych; zgodność protobuf   | Android + iOS; pakiety zgodne z Meshtastic       |

---

# 12. Wymagania w repozytorium: Specification-Driven Development (SDD)

W SDD **specyfikacja jest źródłem prawdy**, a kod, testy i plany powstają z niej (często z pomocą agenta AI). Poniżej zapis wymagań S.U.R.V.I.V.E. w dwóch podejściach. Można użyć obu: BMAD do poziomu produktu (PRD, user stories), Spec Kit do poziomu implementacji poszczególnych funkcji.

## 12.1 Struktura repozytorium

```text
survive/
├── README.md
├── .specify/                          # GitHub Spec Kit
│   ├── memory/
│   │   └── constitution.md            # zasady projektu (offline-first, 868 MHz, testy, bezpieczeństwo)
│   ├── specs/
│   │   ├── 001-position-without-gps/
│   │   │   ├── spec.md                # CO i DLACZEGO (US-1)
│   │   │   ├── plan.md                # JAK: architektura, technologie
│   │   │   ├── data-model.md
│   │   │   ├── contracts/             # np. pakiet POI, POSITION_REQUEST (protobuf)
│   │   │   ├── research.md
│   │   │   └── tasks.md               # lista zadań z plan.md
│   │   ├── 002-hazard-report/
│   │   ├── 003-field-hospital-update/
│   │   ├── 004-evacuation-and-sos/
│   │   └── 005-trusted-nodes/
│   └── templates/
├── docs/                              # BMAD
│   ├── prd.md                         # Product Requirements Document (FR + NFR)
│   ├── architecture.md
│   ├── user-stories/
│   │   ├── US-1-position-without-gps.md
│   │   ├── US-2-hazard-report.md
│   │   ├── US-3-field-hospital-update.md
│   │   ├── US-4-evacuation-and-sos.md
│   │   └── US-5-trusted-nodes.md
│   └── diagrams/
│       ├── use-cases.puml
│       └── requirements.mmd
├── firmware/                          # fork Meshtastic
├── app/                               # Flutter
└── tests/
```

## 12.2 Przykład: `.specify/specs/005-trusted-nodes/spec.md`

```markdown
# Feature Specification: Zarządzanie zaufanymi węzłami

**Feature Branch**: `005-trusted-nodes`
**Status**: Draft
**Powiązania**: US-5, FR6, NFR4

## User Scenarios & Testing

### User Story 1 - Blokowanie węzła zakłócającego (Priority: P1)
Jako cywil chcę zablokować węzeł wysyłający fałszywe dane, aby nie widzieć ich na mapie.

**Why this priority**: dezinformacja o korytarzach może zagrozić życiu.
**Independent Test**: dodanie węzła do blacklisty -> jego pakiety nie trafiają do kolejki ani na mapę.

**Acceptance Scenarios**:
1. **Given** węzeł wysyła > N pakietów/min, **When** próg zostaje przekroczony, **Then** węzeł jest ignorowany i pojawia się alert `SPAM_NODE_BLOCKED` z opcją „Cofnij".
2. **Given** zablokowany węzeł, **When** użytkownik cofa blokadę, **Then** pakiety są ponownie przyjmowane.
3. **Given** restart urządzenia, **When** węzeł się uruchamia, **Then** listy zaufania są odtworzone.

### Edge Cases
- Co jeśli użytkownik zablokuje węzeł będący jedynym łącznikiem do reszty mesh?
- Co jeśli pamięć listy jest pełna (`E5001 STORAGE_FULL`)?

## Requirements

### Functional Requirements
- **FR-001**: System MUSI przechowywać whitelistę i blacklistę lokalnie (węzeł + aplikacja).
- **FR-002**: System MUSI automatycznie ignorować węzeł przekraczający próg pakietów/min.
- **FR-003**: Użytkownik MUSI móc ręcznie cofnąć każdą blokadę.
- **FR-004**: Pakiety od zablokowanych węzłów MUSZĄ być odrzucane przed parsowaniem.

### Non-Functional Requirements
- **NFR-001 (Security)**: odrzucenie pakietu z blacklisty w < 10 ms.
- **NFR-002 (Reliability)**: listy przetrwają zanik zasilania (CRC + numer sekwencji), MTTR ≤ 30 s.

### Key Entities
- **Node**: id, positionSource, trustLevel (WHITELIST/NEUTRAL/BLACKLIST), packetsPerMin.

## Success Criteria
- 0 pakietów z blacklisty widocznych na mapie w teście 100 pakietów.
- Cofnięcie blokady widoczne w ≤ 2 s.

## Review & Acceptance Checklist
- [ ] Brak oznaczeń [NEEDS CLARIFICATION]
- [ ] Wymagania testowalne i jednoznaczne
- [ ] Powiązane NFR mają metryki
```

## 12.3 Przykład BMAD: `docs/user-stories/US-5-trusted-nodes.md`

```markdown
# US-5: Zarządzanie zaufanymi węzłami

**Epic**: Bezpieczeństwo i zaufanie
**Status**: ready-for-dev
**Priorytet**: Should have

## Story
Jako cywil lub wolontariusz
chcę wskazywać węzły zaufane i blokować zakłócające,
aby fałszywe lub spamujące dane nie zalewały mojej mapy.

## Acceptance Criteria
1. Węzeł przekraczający próg spamu jest blokowany automatycznie, a użytkownik widzi alert z opcją cofnięcia.
2. Ręczne dodanie do whitelisty/blacklisty działa w ≤ 2 s.
3. Listy zaufania są odtwarzane po restarcie.

## Tasks
- [ ] `TrustManager` (firmware C++) + testy Unity
- [ ] Ekran S20 „Zaufane węzły" (Flutter)
- [ ] Synchronizacja list app <-> węzeł (BLE)
- [ ] Alert `SPAM_NODE_BLOCKED`

## Dev Notes
- Zgodność z `docs/architecture.md`, sekcja Zaufanie.
- Wymagania powiązane: FR6, NFR4 (patrz `docs/prd.md`).

## Traceability
Use case: UC6 · Diagram: `docs/diagrams/use-cases.puml`
```

## 12.4 Śledzenie (traceability)

|Story|Use case|Spec Kit|BMAD|Wymagania|
|---|---|---|---|---|
|US-1|UC1|`001-position-without-gps`|`US-1-...md`|FR1, NFR1, NFR3|
|US-2|UC2|`002-hazard-report`|`US-2-...md`|FR2, NFR1, NFR4|
|US-3|UC3|`003-field-hospital-update`|`US-3-...md`|FR3, NFR4|
|US-4|UC4, UC5|`004-evacuation-and-sos`|`US-4-...md`|FR4, FR5, NFR2, NFR5|
|US-5|UC6|`005-trusted-nodes`|`US-5-...md`|FR6, NFR4|