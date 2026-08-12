---
layout: default
title: "SparkClean: Mac-Cleaner und Speicheranalyse für Entwickler"
description: "Zeigt, wie viel Platz Xcode, Docker, node_modules, Caches und App-Reste belegen. Erst prüfen, dann gezielt aufräumen."
lang: de
locale: de_DE
direction: ltr
permalink: /de/
markdown_url: https://raw.githubusercontent.com/georgekhananaev/spark-clean/main/docs/de/index.md
asset_base: https://raw.githubusercontent.com/georgekhananaev/spark-clean/main/docs/de/
skip_label: Zum Inhalt springen
language_label: Sprachen
footer_label: Entwickelt von
license_label: Lizenz
issues_label: Probleme
releases_label: Versionen
---

<p class="eyebrow">Native SwiftUI-App für macOS 14 und neuer</p>

# Mehr Platz auf dem Mac, ohne auf Verdacht zu löschen

<p class="lead">Entwicklerwerkzeuge sammeln Daten mit beeindruckender Ausdauer. Beim Aufräumen sind sie weniger gründlich. SparkClean zeigt Xcode-, Docker- und <code>node_modules</code>-Daten, Caches, doppelte Dateien und App-Reste, bevor du entscheidest, was weg kann.</p>

<p class="actions">
  <a class="button primary" href="https://github.com/georgekhananaev/spark-clean/releases/latest">Neueste Version laden</a>
  <a class="button" href="https://github.com/georgekhananaev/spark-clean">Quellcode auf GitHub ansehen</a>
</p>

<img class="product-shot" src="../../screenshots/language-german.png" alt="Deutsche SparkClean-Oberfläche mit Bereinigungskategorien, Risikostufen und freigebbarem Mac-Speicherplatz">

## Aufräumen, was Entwicklerwerkzeuge liegen lassen

SparkClean vereint Cache-Bereinigung, Speicheranalyse, Duplikatsuche und App-Deinstallation
in einer nativen Mac-App. Jeder Bereich lässt sich einzeln scannen. Wer nur Docker prüfen
will, muss nicht auf einen kompletten Systemscan warten.

<div class="feature-grid">
  <article class="feature-card">
    <h3>Entwickler-Caches an einem Ort</h3>
    <p>Xcode DerivedData und Simulatoren, Docker-Ressourcen, node_modules, Homebrew, JetBrains, Python-Umgebungen, Rust-target-Ordner und Caches gängiger Paketmanager prüfen.</p>
  </article>
  <article class="feature-card">
    <h3>Sehen, wohin der Speicherplatz verschwindet</h3>
    <p>Festplattenübersicht und Speicheranalyse arbeiten schreibgeschützt. Sie zeigen große Ordner, App-Daten, APFS-Volumes, lokale Schnappschüsse und Veränderungen beim Speicherverbrauch.</p>
  </article>
  <article class="feature-card">
    <h3>Doppelte Dateien und App-Reste</h3>
    <p>Inhaltsgleiche Dateien werden mit SHA-256 bestätigt. Beim Entfernen einer App lassen sich Caches, Einstellungen, Container, Protokolle und Supportdateien einzeln behalten oder auswählen.</p>
  </article>
  <article class="feature-card">
    <h3>Erst ansehen, dann löschen</h3>
    <p>Funde sind als Sicher, Prüfen oder Vorsicht gekennzeichnet. SparkClean zeigt die Pfade, lässt geschützte Orte in Ruhe und verschiebt bestätigte Dateien standardmäßig in den Papierkorb.</p>
  </article>
</div>

## Alles bleibt auf dem Mac

Scans, Analysen und Bereinigungen laufen lokal. SparkClean braucht kein Konto und verwendet
weder Abos noch Werbung, Nutzungsanalyse oder Telemetrie. Dateinamen, Pfade, Scanergebnisse
und der Bereinigungsverlauf werden nicht hochgeladen. Eine Verbindung nach außen gibt es nur
für die optionale GitHub-Versionsprüfung und für Downloads, die du selbst startest.

<div class="notice">
  <p><strong>Ein Rückweg bleibt offen.</strong> Solange der Papierkorb nicht geleert wurde, lässt sich die letzte Bereinigung über den Papierkorb mit <strong>Umschalt+Cmd+Z</strong> wiederherstellen. Nicht wiederherstellbare Befehle wie Docker-Pruning werden vor der Bestätigung klar getrennt angezeigt.</p>
</div>

## Fünf Sprachen, direkt in der App

SparkClean enthält Englisch, vereinfachtes Chinesisch, Japanisch, Deutsch und Hebräisch.
Die Auswahl findest du unter **Einstellungen → Allgemein → App-Sprache**. Danach startet
die App auf Wunsch neu.

Viele nicht englische Texte entstanden zunächst mit KI-Unterstützung. Das ist eine
Arbeitsgrundlage, kein Qualitätsstempel. Wenn eine Formulierung steif klingt, fachlich nicht
passt oder einfach niemand so sagen würde, ist auch die Korrektur eines einzigen Satzes
willkommen. Der
[Leitfaden für Übersetzungsbeiträge](https://github.com/georgekhananaev/spark-clean/blob/main/docs/TRANSLATIONS.md)
erklärt den Ablauf.

## Häufige Fragen

### Was räumt SparkClean auf?

Die App findet neu erzeugbare Caches, Protokolle, temporäre Daten, alte Installationsdateien,
Entwicklungsartefakte, lange ungenutzte Apps und App-Reste. Was unterstützt und aus
Sicherheitsgründen bewusst ausgelassen wird, steht in der
[Funktionsübersicht](https://github.com/georgekhananaev/spark-clean/blob/main/SUPPORTED.md).

### Ist SparkClean Open Source?

Der vollständige Quellcode lässt sich einsehen und ändern. Private, schulische, akademische
und andere nicht kommerzielle Nutzung ist im Rahmen der nicht kommerziellen Lizenz kostenlos.
SparkClean ist source-available, aber keine OSI-anerkannte Open-Source-Software.

### Lässt sich eine Bereinigung rückgängig machen?

Ausgewählte Dateien landen standardmäßig im Papierkorb. Solange er nicht geleert wurde,
kann die letzte Bereinigung wiederhergestellt werden. Dauerhaftes Löschen muss ausdrücklich
aktiviert werden und bleibt durch Kategorie- und Pfadregeln eingeschränkt.

### Welche Macs werden unterstützt?

Benötigt wird macOS 14 Sonoma oder neuer. Macs mit Apple-Chip und Intel-Macs werden unterstützt.

## Download, Dokumentation und Hilfe

<ul class="link-list">
  <li><a href="https://github.com/georgekhananaev/spark-clean/releases/latest">SparkClean über GitHub Releases laden</a></li>
  <li><a href="https://github.com/georgekhananaev/spark-clean/blob/main/README.md">Vollständige Anleitung und Bildschirmfotos ansehen</a></li>
  <li><a href="https://github.com/georgekhananaev/spark-clean/issues">Fehler melden oder eine Funktion vorschlagen</a></li>
  <li><a href="https://github.com/georgekhananaev/spark-clean/blob/main/CONTRIBUTING.md">Code, Dokumentation oder Übersetzungen beitragen</a></li>
</ul>
