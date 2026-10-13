# Zasady pracy w projekcie Bezpieczny Krok

- Stack: Kotlin, Jetpack Compose (Material 3), MVVM, Room, Coroutines/Flow. Nie dodawaj bibliotek bez uzasadnienia.
- Pracuj małymi pionowymi kawałkami: jedna funkcja = jeden mały PR, który się buduje i działa.
- Po każdej zmianie upewnij się, że projekt się kompiluje.
- Priorytet: wykrywanie upadku → odliczanie → alarm SMS. Nie rozbudowuj rzeczy z sekcji „Poza MVP”.
- Interfejs dla seniora: duże elementy, wysoki kontrast, mało tekstu, jedna akcja na ekran.
- Progi i parametry algorytmu trzymaj w jednym miejscu (np. `DetectionConfig`).
- Logikę wykrywania pisz jako czystą klasę Kotlin bez zależności od Androida, żeby dało się ją testować jednostkowo.
- Komentarze i nazwy w kodzie po angielsku, teksty widoczne dla użytkownika po polsku (zasoby `strings.xml`).
- Bezpieczeństwo: dane kontaktów i lokalizacja zostają na urządzeniu, nie loguj ich.
