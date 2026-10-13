#!/usr/bin/env bash
set -euo pipefail

OWNER="${OWNER:-szymonqk}"
REPO="${REPO:-bezpieczny-krok}"
API="https://api.github.com"
PROJECT_TITLE="Bezpieczny Krok - Roadmapa MVP"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Błąd: ustaw GITHUB_TOKEN przed uruchomieniem skryptu." >&2
  echo "Przykład: GITHUB_TOKEN=... OWNER=szymonqk REPO=bezpieczny-krok bash scripts/setup-roadmap.sh" >&2
  exit 1
fi

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Błąd: wymagane narzędzie '$cmd' nie jest dostępne." >&2
    exit 1
  fi
done

api() {
  local method="$1"; shift
  local path="$1"; shift
  local data="${1:-}"
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$API$path" \
      -d "$data"
  else
    curl -sS -X "$method" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$API$path"
  fi
}

graphql() {
  local query="$1"
  local variables="${2:-{}}"
  curl -sS -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/vnd.github+json" \
    "$API/graphql" \
    -d "$(jq -cn --arg q "$query" --argjson v "$variables" '{query:$q,variables:$v}')"
}

ensure_label() {
  local name="$1" color="$2" description="$3"
  local status
  status=$(curl -sS -o /tmp/label_resp.json -w "%{http_code}" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$API/repos/$OWNER/$REPO/labels/$name")

  local payload
  payload=$(jq -cn --arg name "$name" --arg color "$color" --arg description "$description" '{name:$name,color:$color,description:$description}')

  if [[ "$status" == "200" ]]; then
    api PATCH "/repos/$OWNER/$REPO/labels/$name" "$payload" >/dev/null
    echo "Label zaktualizowany: $name"
  else
    api POST "/repos/$OWNER/$REPO/labels" "$payload" >/dev/null
    echo "Label utworzony: $name"
  fi
}

MILESTONE_MAP_FILE="/tmp/roadmap_milestones.json"
echo '{}' > "$MILESTONE_MAP_FILE"

ensure_milestone() {
  local title="$1" due_date="$2"
  local due_on="${due_date}T23:59:59Z"

  local existing
  existing=$(api GET "/repos/$OWNER/$REPO/milestones?state=all&per_page=100" | jq -r --arg t "$title" '.[] | select(.title==$t) | .number' | head -n1)

  local payload
  payload=$(jq -cn --arg title "$title" --arg due_on "$due_on" '{title:$title,due_on:$due_on,state:"open"}')

  local number
  if [[ -n "$existing" ]]; then
    api PATCH "/repos/$OWNER/$REPO/milestones/$existing" "$payload" >/dev/null
    number="$existing"
    echo "Milestone zaktualizowany: $title"
  else
    number=$(api POST "/repos/$OWNER/$REPO/milestones" "$payload" | jq -r '.number')
    echo "Milestone utworzony: $title"
  fi

  jq --arg t "$title" --argjson n "$number" '. + {($t):$n}' "$MILESTONE_MAP_FILE" > /tmp/roadmap_milestones_new.json
  mv /tmp/roadmap_milestones_new.json "$MILESTONE_MAP_FILE"
}

ISSUE_NODE_IDS_FILE="/tmp/roadmap_issue_node_ids.txt"
: > "$ISSUE_NODE_IDS_FILE"

find_issue_by_title() {
  local title="$1"
  api GET "/repos/$OWNER/$REPO/issues?state=all&per_page=100" | jq -c --arg t "$title" '.[] | select(.title==$t) | {number,node_id}' | head -n1
}

create_or_keep_issue() {
  local title="$1" goal="$2" milestone_title="$3" labels_csv="$4" acceptance_json="$5"

  local existing
  existing=$(find_issue_by_title "$title")

  local body
  body=$(jq -rn --arg goal "$goal" --argjson ac "$acceptance_json" '$goal + "\n\n## Kryteria akceptacji\n" + ($ac | map("- [ ] " + .) | join("\n"))')

  if [[ -n "$existing" ]]; then
    local existing_num existing_node_id
    existing_num=$(jq -r '.number' <<<"$existing")
    existing_node_id=$(jq -r '.node_id' <<<"$existing")
    echo "Issue już istnieje (#$existing_num): $title"
    echo "$existing_node_id" >> "$ISSUE_NODE_IDS_FILE"
    return
  fi

  local labels_json milestone_number payload response number node_id
  labels_json=$(jq -cn --arg labels "$labels_csv" '$labels | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length>0))')

  if [[ -n "$milestone_title" ]]; then
    milestone_number=$(jq -r --arg t "$milestone_title" '.[$t]' "$MILESTONE_MAP_FILE")
    payload=$(jq -cn \
      --arg title "$title" \
      --arg body "$body" \
      --argjson labels "$labels_json" \
      --argjson milestone "$milestone_number" \
      '{title:$title,body:$body,labels:$labels,milestone:$milestone}')
  else
    payload=$(jq -cn \
      --arg title "$title" \
      --arg body "$body" \
      --argjson labels "$labels_json" \
      '{title:$title,body:$body,labels:$labels}')
  fi

  response=$(api POST "/repos/$OWNER/$REPO/issues" "$payload")
  number=$(jq -r '.number' <<<"$response")
  node_id=$(jq -r '.node_id' <<<"$response")

  if [[ "$number" == "null" || -z "$number" ]]; then
    echo "Błąd podczas tworzenia issue: $title" >&2
    echo "$response" >&2
    exit 1
  fi

  echo "Issue utworzony (#$number): $title"
  echo "$node_id" >> "$ISSUE_NODE_IDS_FILE"
}

ensure_project_and_add_items() {
  local owner_query owner_data owner_id project_id

  owner_query='query($login:String!){user(login:$login){id projectsV2(first:50){nodes{id title}}}}'
  owner_data=$(graphql "$owner_query" "$(jq -cn --arg login "$OWNER" '{login:$login}')")

  if [[ "$(jq -r '.errors // empty | length' <<<"$owner_data")" != "" && "$(jq -r '.errors | length' <<<"$owner_data")" != "0" ]]; then
    echo "Nie udało się odczytać użytkownika/projektów: $(jq -c '.errors' <<<"$owner_data")" >&2
    return 1
  fi

  owner_id=$(jq -r '.data.user.id // empty' <<<"$owner_data")
  project_id=$(jq -r --arg t "$PROJECT_TITLE" '.data.user.projectsV2.nodes[]? | select(.title==$t) | .id' <<<"$owner_data" | head -n1)

  if [[ -z "$owner_id" ]]; then
    echo "Nie udało się pobrać owner_id dla użytkownika $OWNER" >&2
    return 1
  fi

  if [[ -z "$project_id" ]]; then
    local create_project_mut create_resp
    create_project_mut='mutation($ownerId:ID!, $title:String!){createProjectV2(input:{ownerId:$ownerId,title:$title}){projectV2{id}}}'
    create_resp=$(graphql "$create_project_mut" "$(jq -cn --arg ownerId "$owner_id" --arg title "$PROJECT_TITLE" '{ownerId:$ownerId,title:$title}')")
    project_id=$(jq -r '.data.createProjectV2.projectV2.id // empty' <<<"$create_resp")
    if [[ -z "$project_id" ]]; then
      echo "Nie udało się utworzyć projektu: $(jq -c '.errors // .data' <<<"$create_resp")" >&2
      return 1
    fi
    echo "Projekt utworzony: $PROJECT_TITLE"
  else
    echo "Projekt już istnieje: $PROJECT_TITLE"
  fi

  local fields_query fields_resp status_field_id backlog_option_id
  fields_query='query($projectId:ID!){node(id:$projectId){... on ProjectV2{fields(first:50){nodes{... on ProjectV2SingleSelectField{id name options{id name}} ... on ProjectV2FieldCommon{id name}}}}}}'
  fields_resp=$(graphql "$fields_query" "$(jq -cn --arg projectId "$project_id" '{projectId:$projectId}')")

  status_field_id=$(jq -r '.data.node.fields.nodes[]? | select(.name=="Status") | .id' <<<"$fields_resp" | head -n1)
  backlog_option_id=$(jq -r '.data.node.fields.nodes[]? | select(.name=="Status") | .options[]? | select(.name=="Backlog") | .id' <<<"$fields_resp" | head -n1)

  if [[ -z "$status_field_id" || -z "$backlog_option_id" ]]; then
    echo "Projekt nie ma kolumny Status/Backlog; pomijam ustawianie kolumny."
  fi

  while IFS= read -r issue_node_id; do
    [[ -z "$issue_node_id" ]] && continue
    local add_item_mut add_resp item_id
    add_item_mut='mutation($projectId:ID!,$contentId:ID!){addProjectV2ItemById(input:{projectId:$projectId,contentId:$contentId}){item{id}}}'
    add_resp=$(graphql "$add_item_mut" "$(jq -cn --arg projectId "$project_id" --arg contentId "$issue_node_id" '{projectId:$projectId,contentId:$contentId}')")
    item_id=$(jq -r '.data.addProjectV2ItemById.item.id // empty' <<<"$add_resp")

    if [[ -z "$item_id" ]]; then
      local err
      err=$(jq -r '.errors[0].message // empty' <<<"$add_resp")
      if [[ "$err" == *"already exists"* ]]; then
        continue
      fi
      echo "Nie udało się dodać issue do projektu (node_id=$issue_node_id): $(jq -c '.errors // .data' <<<"$add_resp")" >&2
      continue
    fi

    if [[ -n "$status_field_id" && -n "$backlog_option_id" ]]; then
      local set_field_mut
      set_field_mut='mutation($projectId:ID!, $itemId:ID!, $fieldId:ID!, $optionId:String!){updateProjectV2ItemFieldValue(input:{projectId:$projectId,itemId:$itemId,fieldId:$fieldId,value:{singleSelectOptionId:$optionId}}){projectV2Item{id}}}'
      graphql "$set_field_mut" "$(jq -cn --arg projectId "$project_id" --arg itemId "$item_id" --arg fieldId "$status_field_id" --arg optionId "$backlog_option_id" '{projectId:$projectId,itemId:$itemId,fieldId:$fieldId,optionId:$optionId}')" >/dev/null || true
    fi
  done < "$ISSUE_NODE_IDS_FILE"

  echo "Dodano/przypisano issue do projektu: $PROJECT_TITLE"
  return 0
}

echo "==> Tworzenie/aktualizacja etykiet"
ensure_label "core" "B60205" "Kluczowa funkcja MVP ratująca zdrowie/życie"
ensure_label "ui" "1D76DB" "Interfejs użytkownika i UX"
ensure_label "sensors" "0E8A16" "Czujniki urządzenia i praca w tle"
ensure_label "detection" "7B3FE4" "Algorytm wykrywania upadku"
ensure_label "alerting" "D93F0B" "Alarmowanie: SMS, połączenia, lokalizacja"
ensure_label "post-mvp" "6E7781" "Zakres zaplanowany po wydaniu MVP"
ensure_label "bug" "D73A4A" "Błąd lub regresja wymagająca poprawki"

echo "==> Tworzenie/aktualizacja milestone'ów"
ensure_milestone "Etap 0: Fundament" "2026-10-19"
ensure_milestone "Etap 1: Interfejs na atrapach" "2026-11-09"
ensure_milestone "Etap 2: Czujniki i usługa w tle" "2026-11-23"
ensure_milestone "Etap 3: Wykrywanie upadku" "2026-12-07"
ensure_milestone "Etap 4: Alarmowanie" "2026-12-21"
ensure_milestone "Etap 5: Stabilizacja i beta" "2027-01-05"

echo "==> Tworzenie issue (25 z checklisty + 6 post-MVP)"

create_or_keep_issue "Projekt Android Studio (Kotlin, Compose, Material 3), struktura pakietów MVVM" \
"Cel: uruchomić bazowy projekt Android z Compose i strukturą MVVM gotową do dalszych etapów roadmapy." \
"Etap 0: Fundament" "ui" \
"[\"Aplikacja uruchamia się na telefonie z Androidem 8+ bez crasha\",\"Struktura pakietów MVVM jest widoczna w projekcie\",\"Ekran startowy Compose renderuje się poprawnie\"]"

create_or_keep_issue "Konfiguracja Git, .gitignore, CI z buildem (GitHub Actions)" \
"Cel: zapewnić powtarzalny workflow developerski i automatyczny build po zmianach." \
"Etap 0: Fundament" "ui" \
"[\"Repozytorium ma poprawny .gitignore dla Android/Kotlin\",\"Workflow CI uruchamia build po pushu\",\"Status builda jest widoczny w GitHub Actions\"]"

create_or_keep_issue "Motyw dla seniorów (duże czcionki, wysoki kontrast)" \
"Cel: przygotować domyślny motyw UI czytelny dla seniorów." \
"Etap 0: Fundament" "core,ui" \
"[\"Najważniejsze ekrany używają dużych rozmiarów tekstu\",\"Kontrast tekstu i tła jest wyraźny na telefonie\",\"Przyciski są łatwe do trafienia jedną ręką\"]"

create_or_keep_issue "Nawigacja (Navigation Compose)" \
"Cel: wdrożyć prostą i stabilną nawigację między ekranami MVP." \
"Etap 1: Interfejs na atrapach" "ui" \
"[\"Przejścia między głównymi ekranami działają na telefonie\",\"Przycisk wstecz wraca do poprzedniego ekranu\",\"Brak pętli nawigacji i crashy przy szybkim klikaniu\"]"

create_or_keep_issue "Ekran onboardingu (wyjaśnienie działania, prośba o uprawnienia)" \
"Cel: wprowadzić użytkownika w działanie aplikacji i poprosić o kluczowe uprawnienia." \
"Etap 1: Interfejs na atrapach" "core,ui" \
"[\"Użytkownik widzi krótki opis działania aplikacji\",\"Z poziomu onboardingu można przejść do prośby o uprawnienia\",\"Po zakończeniu onboardingu aplikacja przechodzi do ekranu głównego\"]"

create_or_keep_issue "Ekran główny ze statusem 'Ochrona włączona / wyłączona'" \
"Cel: umożliwić szybkie sprawdzenie i zmianę stanu ochrony." \
"Etap 1: Interfejs na atrapach" "core,ui" \
"[\"Ekran pokazuje aktualny stan ochrony\",\"Zmiana stanu jest widoczna od razu na ekranie\",\"Elementy są czytelne i duże na telefonie\"]"

create_or_keep_issue "Ekran kontaktów alarmowych (dodaj, edytuj, usuń; zapis w Room)" \
"Cel: dać użytkownikowi możliwość zarządzania kontaktami alarmowymi lokalnie w telefonie." \
"Etap 1: Interfejs na atrapach" "core,ui,alerting" \
"[\"Można dodać nowy kontakt alarmowy\",\"Można edytować i usunąć istniejący kontakt\",\"Po restarcie aplikacji kontakty pozostają zapisane\"]"

create_or_keep_issue "Ekran ustawień (czas odliczania, czułość, treść SMS)" \
"Cel: umożliwić konfigurację kluczowych parametrów alarmowania i detekcji." \
"Etap 1: Interfejs na atrapach" "core,ui,detection,alerting" \
"[\"Użytkownik może ustawić czas odliczania\",\"Użytkownik może zmienić czułość wykrywania\",\"Użytkownik może edytować treść SMS alarmowego\",\"Ustawienia pozostają po ponownym uruchomieniu aplikacji\"]"

create_or_keep_issue "Ekran alarmu z odliczaniem i przyciskiem 'Nic mi nie jest'" \
"Cel: dodać czytelny ekran anulowania alarmu przed wysyłką powiadomień." \
"Etap 1: Interfejs na atrapach" "core,ui,alerting" \
"[\"Po uruchomieniu alarmu widać odliczanie czasu\",\"Duży przycisk 'Nic mi nie jest' zatrzymuje alarm\",\"Po anulowaniu użytkownik wraca do stanu bez alarmu\"]"

create_or_keep_issue "Odczyt akcelerometru i żyroskopu (SensorManager)" \
"Cel: zbierać dane z czujników potrzebne do wykrywania upadku." \
"Etap 2: Czujniki i usługa w tle" "core,sensors,detection" \
"[\"Aplikacja odczytuje dane z akcelerometru na wspieranym telefonie\",\"Aplikacja odczytuje dane z żyroskopu\",\"Zmiany ruchu są widoczne w podglądzie diagnostycznym\"]"

create_or_keep_issue "Foreground service z trwałym powiadomieniem" \
"Cel: utrzymać działanie ochrony w tle podczas normalnego używania telefonu." \
"Etap 2: Czujniki i usługa w tle" "core,sensors" \
"[\"Po włączeniu ochrony działa foreground service\",\"Widoczne jest trwałe powiadomienie systemowe\",\"Po wygaszeniu ekranu usługa nadal działa\"]"

create_or_keep_issue "Tryb nagrywania danych do CSV (do dostrajania algorytmu)" \
"Cel: umożliwić zapis sesji z czujników do analizy i strojenia progów." \
"Etap 2: Czujniki i usługa w tle" "sensors,detection" \
"[\"Użytkownik może rozpocząć i zatrzymać nagrywanie danych\",\"Plik CSV zawiera znaczniki czasu i wartości czujników\",\"Plik CSV jest dostępny do eksportu z telefonu\"]"

create_or_keep_issue "Obsługa ograniczeń baterii (prośba o wyłączenie optymalizacji)" \
"Cel: ograniczyć ryzyko ubijania działania aplikacji w tle przez system." \
"Etap 2: Czujniki i usługa w tle" "core,sensors" \
"[\"Aplikacja wykrywa aktywną optymalizację baterii\",\"Użytkownik dostaje jasną instrukcję wyłączenia optymalizacji\",\"Po powrocie do aplikacji status konfiguracji jest widoczny\"]"

create_or_keep_issue "Algorytm progowy: swobodny spadek → uderzenie → bezruch" \
"Cel: zaimplementować podstawową logikę wykrywania upadku zgodną z roadmapą MVP." \
"Etap 3: Wykrywanie upadku" "core,sensors,detection" \
"[\"Algorytm wykrywa sekwencję spadek-uderzenie-bezruch\",\"Wykrycie generuje zdarzenie alarmowe\",\"Przy zwykłym chodzeniu alarm nie uruchamia się automatycznie\"]"

create_or_keep_issue "Parametry progów w jednym miejscu, łatwe do zmiany" \
"Cel: scentralizować konfigurację progów, by łatwo stroić detekcję." \
"Etap 3: Wykrywanie upadku" "core,detection" \
"[\"Wszystkie progi są w jednym module/klasie konfiguracyjnej\",\"Zmiana progu nie wymaga modyfikowania wielu plików\",\"Po zmianie progów aplikacja działa bez regresji\"]"

create_or_keep_issue "Testy jednostkowe na nagranych danych (upadki vs. czynności codzienne)" \
"Cel: potwierdzić działanie algorytmu na danych testowych przed testami terenowymi." \
"Etap 3: Wykrywanie upadku" "detection" \
"[\"Testy uruchamiają się lokalnie i w CI\",\"Dla próbek upadku algorytm zwraca wykrycie\",\"Dla próbek codziennych aktywności liczba fałszywych alarmów jest raportowana\"]"

create_or_keep_issue "Połączenie z ekranem odliczania" \
"Cel: po wykryciu upadku przejść automatycznie do ekranu odliczania alarmu." \
"Etap 3: Wykrywanie upadku" "core,detection,alerting,ui" \
"[\"Wykryty upadek otwiera ekran odliczania\",\"Odliczanie startuje automatycznie\",\"Anulowanie odliczania zatrzymuje dalsze alarmowanie\"]"

create_or_keep_issue "Pobranie lokalizacji (Fused Location Provider)" \
"Cel: pobierać aktualną lokalizację do wiadomości alarmowej." \
"Etap 4: Alarmowanie" "core,alerting" \
"[\"Aplikacja pobiera lokalizację po uruchomieniu alarmu\",\"Gdy lokalizacja jest niedostępna, użytkownik widzi czytelną informację\",\"W przypadku sukcesu lokalizacja trafia do payloadu alarmowego\"]"

create_or_keep_issue "Wysyłka SMS do kontaktów z linkiem do mapy" \
"Cel: wysłać alarm SMS z lokalizacją do skonfigurowanych bliskich." \
"Etap 4: Alarmowanie" "core,alerting" \
"[\"Po zakończeniu odliczania wysyłany jest SMS do wszystkich kontaktów\",\"SMS zawiera link do mapy z lokalizacją\",\"Błędy wysyłki są sygnalizowane użytkownikowi\"]"

create_or_keep_issue "Opcjonalne automatyczne połączenie z pierwszym kontaktem" \
"Cel: umożliwić dodatkowe alarmowanie głosowe po wysłaniu SMS." \
"Etap 4: Alarmowanie" "core,alerting" \
"[\"Ustawienie opcji auto-połączenia jest dostępne w aplikacji\",\"Po wysyłce SMS aplikacja inicjuje połączenie z pierwszym kontaktem\",\"Gdy opcja jest wyłączona, połączenie nie jest wykonywane\"]"

create_or_keep_issue "Obsługa uprawnień (SMS, lokalizacja, powiadomienia) i ich odmowy" \
"Cel: poprawnie obsłużyć cały przepływ zgód i odmów krytycznych uprawnień." \
"Etap 4: Alarmowanie" "core,alerting,ui" \
"[\"Aplikacja prosi o wymagane uprawnienia we właściwym momencie\",\"Po odmowie użytkownik dostaje jasny komunikat i możliwe kroki\",\"Po ponownym nadaniu uprawnień funkcje alarmowe działają poprawnie\"]"

create_or_keep_issue "Testy na kilku telefonach (w tym Samsung i Xiaomi)" \
"Cel: zweryfikować działanie aplikacji na różnych producentach i nakładkach." \
"Etap 5: Stabilizacja i beta" "core,bug" \
"[\"Przeprowadzono checklistę testów na co najmniej 2 modelach (Samsung, Xiaomi)\",\"Wyniki testów i różnice zachowań zostały zapisane\",\"Krytyczne problemy blokujące alarmowanie są wyłapane\"]"

create_or_keep_issue "Redukcja fałszywych alarmów i zużycia baterii" \
"Cel: zmniejszyć liczbę fałszywych alarmów oraz koszt energetyczny działania ochrony." \
"Etap 5: Stabilizacja i beta" "core,detection,sensors,bug" \
"[\"Porównanie przed/po pokazuje spadek fałszywych alarmów\",\"Pomiar baterii wskazuje poprawę lub brak regresji\",\"Zmiany nie pogarszają skuteczności wykrycia rzeczywistego upadku\"]"

create_or_keep_issue "Poprawki UX po teście z prawdziwym seniorem" \
"Cel: wprowadzić poprawki użyteczności wynikające z testu z użytkownikiem docelowym." \
"Etap 5: Stabilizacja i beta" "core,ui" \
"[\"Przeprowadzono test zadaniowy z co najmniej jednym seniorem\",\"Wprowadzono poprawki dla zgłoszonych problemów krytycznych\",\"Po poprawkach użytkownik kończy podstawowy scenariusz bez pomocy\"]"

create_or_keep_issue "Wersja beta (APK)" \
"Cel: przygotować i udostępnić stabilną wersję beta do testów terenowych." \
"Etap 5: Stabilizacja i beta" "core" \
"[\"APK beta buduje się bez błędów\",\"APK można zainstalować na telefonie testowym\",\"Scenariusz: wykrycie -> odliczanie -> SMS przechodzi end-to-end\"]"

create_or_keep_issue "[Poza MVP] Warstwa AI/ML rozróżniająca upadek od zwykłych ruchów" \
"Cel: przygotować backlog wymagań dla przyszłej warstwy AI/ML poprawiającej precyzję detekcji." \
"" "post-mvp" \
"[\"Opisano zakres i dane potrzebne do treningu\",\"Zdefiniowano metryki sukcesu modelu\",\"Nie blokuje realizacji bieżącego MVP\"]"

create_or_keep_issue "[Poza MVP] Powiadamianie służb ratunkowych (112): analiza prawna i techniczna" \
"Cel: zebrać wymagania i ograniczenia dla ewentualnej integracji z numerem 112." \
"" "post-mvp" \
"[\"Udokumentowano ryzyka prawne i regulacyjne\",\"Opisano możliwe warianty techniczne\",\"Decyzja o dalszych krokach nie wpływa na MVP\"]"

create_or_keep_issue "[Poza MVP] Aplikacja dla bliskich + backend (Firebase, push)" \
"Cel: zdefiniować przyszły zakres aplikacji towarzyszącej i backendu powiadomień." \
"" "post-mvp" \
"[\"Powstał wstępny opis architektury klient + backend\",\"Zebrano listę kluczowych scenariuszy użytkownika\",\"Zakres jest odseparowany od MVP offline-first\"]"

create_or_keep_issue "[Poza MVP] Wear OS (smartwatch)" \
"Cel: ocenić opłacalność i zakres wsparcia smartwatcha w kolejnych etapach." \
"" "post-mvp" \
"[\"Zidentyfikowano główne przypadki użycia na zegarku\",\"Opisano ograniczenia baterii i czujników\",\"Brak zależności blokujących MVP na telefonie\"]"

create_or_keep_issue "[Poza MVP] Wykrywanie wypadków samochodowych" \
"Cel: przygotować oddzielny backlog dla scenariusza wypadków drogowych." \
"" "post-mvp" \
"[\"Opisano różnice względem wykrywania upadku pieszego\",\"Zdefiniowano dodatkowe sygnały/czujniki do analizy\",\"Zakres nie miesza się z priorytetami MVP\"]"

create_or_keep_issue "[Poza MVP] iOS" \
"Cel: udokumentować warunki wejścia w rozwój wersji iOS po domknięciu MVP Android." \
"" "post-mvp" \
"[\"Zebrano wymagania funkcjonalne parytetu z Android MVP\",\"Wstępnie oszacowano koszt i ryzyka\",\"Decyzja o starcie iOS została odłożona po MVP\"]"

echo "==> Próba konfiguracji projektu (board + kolumny)"
if ensure_project_and_add_items; then
  echo "Projekt skonfigurowany lub uzupełniony poprawnie."
else
  echo "UWAGA: nie udało się utworzyć/uzupełnić projektu. Sprawdź log powyżej." >&2
fi

echo "==> Gotowe"
