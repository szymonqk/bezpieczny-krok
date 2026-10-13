# Roadmapa: Bezpieczny Krok

Aplikacja na Androida dla seniorów. Wykrywa upadek, daje użytkownikowi chwilę na anulowanie, a jeśli nie odpowie, wysyła bliskim SMS z lokalizacją.

**Platforma:** Android (Kotlin, Jetpack Compose, min SDK 26)
**Termin MVP:** 12 tygodni od startu (13.10.2026 → ok. 5.01.2027)
**Zasada:** najpierw to, co ratuje człowieka. Wszystko inne jest po MVP.

## Funkcje główne (MVP)

1. **Wykrywanie upadku** z akcelerometru i żyroskopu (algorytm progowy: swobodny spadek → uderzenie → bezruch)
2. **Ekran odliczania** „Czy wszystko w porządku?” z dużym przyciskiem „Nic mi nie jest” (domyślnie 30 s)
3. **Alarm do bliskich:** SMS z lokalizacją GPS do zapisanych kontaktów, opcjonalnie automatyczne połączenie
4. **Działanie w tle:** foreground service, który nie jest zabijany przez system
5. **Prosty interfejs dla seniora:** duże przyciski, wysoki kontrast, minimum ekranów

## Poza MVP (świadomie odłożone)

- Warstwa AI/ML rozróżniająca upadek od zwykłych ruchów
- Powiadamianie służb ratunkowych (112): wymaga analizy prawnej i technicznej
- Aplikacja dla bliskich + backend (Firebase, push)
- Wear OS (smartwatch)
- Wykrywanie wypadków samochodowych
- iOS

## Etapy

### Etap 0: Fundament (tydzień 1)
- [ ] Projekt Android Studio (Kotlin, Compose, Material 3), struktura pakietów MVVM
- [ ] Konfiguracja Git, `.gitignore`, CI z buildem (GitHub Actions)
- [ ] Motyw dla seniorów (duże czcionki, wysoki kontrast)

### Etap 1: Interfejs na atrapach (tygodnie 2–4)
- [ ] Nawigacja (Navigation Compose)
- [ ] Ekran onboardingu (wyjaśnienie działania, prośba o uprawnienia)
- [ ] Ekran główny ze statusem „Ochrona włączona / wyłączona”
- [ ] Ekran kontaktów alarmowych (dodaj, edytuj, usuń; zapis w Room)
- [ ] Ekran ustawień (czas odliczania, czułość, treść SMS)
- [ ] Ekran alarmu z odliczaniem i przyciskiem „Nic mi nie jest”

### Etap 2: Czujniki i usługa w tle (tygodnie 4–6)
- [ ] Odczyt akcelerometru i żyroskopu (`SensorManager`)
- [ ] Foreground service z trwałym powiadomieniem
- [ ] Tryb nagrywania danych do CSV (do dostrajania algorytmu)
- [ ] Obsługa ograniczeń baterii (prośba o wyłączenie optymalizacji)

### Etap 3: Wykrywanie upadku (tygodnie 6–8)
- [ ] Algorytm progowy: swobodny spadek → uderzenie → bezruch
- [ ] Parametry progów w jednym miejscu, łatwe do zmiany
- [ ] Testy jednostkowe na nagranych danych (upadki vs. czynności codzienne)
- [ ] Połączenie z ekranem odliczania

### Etap 4: Alarmowanie (tygodnie 8–10)
- [ ] Pobranie lokalizacji (Fused Location Provider)
- [ ] Wysyłka SMS do kontaktów z linkiem do mapy
- [ ] Opcjonalne automatyczne połączenie z pierwszym kontaktem
- [ ] Obsługa uprawnień (SMS, lokalizacja, powiadomienia) i ich odmowy

### Etap 5: Stabilizacja i beta (tygodnie 10–12)
- [ ] Testy na kilku telefonach (w tym Samsung i Xiaomi)
- [ ] Redukcja fałszywych alarmów i zużycia baterii
- [ ] Poprawki UX po teście z prawdziwym seniorem
- [ ] Wersja beta (APK)

## Ryzyka

| Ryzyko | Reakcja |
|---|---|
| Fałszywe alarmy | Dostrajanie na realnych danych, regulowana czułość |
| Zabijanie usługi w tle przez producentów | Foreground service, instrukcje dla użytkownika |
| Brak czasu | Ciąć rzeczy z końca listy, nigdy czujników ani alarmu |
