# W11AUTO

Windows 11 -asennusmedia: asentaja valitsee levyn, ja kaikki muu on automaattista. Kone asentuu, päivittää itsensä loppuun ja lähettää raportin näytölle ja Discordiin.

## Rakennus (Windows, järjestelmänvalvoja)

Vaatii [Windows ADK:n ja WinPE-lisäosan](https://learn.microsoft.com/windows-hardware/get-started/adk-install) (versio 10.1.26100.2454 tai uudempi) sekä suomenkielisen Windows 11 -ISO:n.

```powershell
Copy-Item config.example.json config.json   # DiscordWebhook, SysprepDefault
.\Build-Media.ps1 -IsoPath D:\Win11_Finnish_x64.iso -DownloadUpdates
.\Build-Media.ps1 -PayloadOnly              # päivitä vain skriptit valmiille levylle
.\Build-Media.ps1 -IsoPath D:\Win11.iso -Target Iso -ReuseImage   # ISO Hyper-V-testiin
```

| Parametri | |
|---|---|
| `-DownloadUpdates` | Uusin kumulatiivinen päivitys ja .NET-päivitys Microsoft Update Catalogista levykuvaan. Aja kuukausittain päivityspäivän (kuun 2. tiistai) jälkeen. Jos haku ei toimi, lataa `.msu`-tiedostot käsin kansioon `Updates\`. |
| `-Compression fast` | NVMe-levylle: levykuva on noin 30 % isompi, mutta kirjoittuu nopeammin |
| `-EditionId` | `Core` = Home (oletus), `Professional` = Pro |
| `-BootEx` | Windows UEFI CA 2023 -allekirjoitetut käynnistystiedostot (koneet, jotka eivät luota vuoden 2011 varmenteeseen) |

Käy mikä tahansa USB-levy: tikku tai NVMe USB-kotelossa. Levylle tulee kaksi osiota: FAT32-käynnistysosio ja NTFS-dataosio.

## Käyttö

1. Käynnistä kone USB-levyltä, anna levyn numero ja vahvista se kirjoittamalla numero uudelleen. `S` vaihtaa sysprepin päälle tai pois.
2. Kun ruutu sanoo **IRROTA USB-LEVY**, irrota levy. Kone käynnistyy uudelleen itse, ja levy on vapaa seuraavalle koneelle.
3. **Työpöydällä:**
   - Laturi ja netti tarkistetaan ennen päivityksiä ja ennen jokaista uudelleenkäynnistystä. Jos jompikumpi puuttuu, ruutu muuttuu punaiseksi ja kuuluu hiljainen äänimerkki (`W` = Wi-Fi). Jos odotus kestää yli 5 min, Discordiin lähtee hälytys.
   - Jos emolevyn avain on eri versiolle (esim. Pro), versio vaihdetaan.
   - Päivitykset asennetaan ja kone käynnistyy uudelleen, kunnes päivityksiä ei ole jäljellä (enintään 12 kierrosta).
   - Lopuksi Defenderin määritykset ja Store-sovellukset päivitetään.
4. **Raportti** näytölle, Discordiin ja tiedostoon `C:\Windows\Logs\W11AUTO\`. Siinä on:
   - aktivointi
   - ajurittomat laitteet
   - akun ja levyn kunto
   - TPM ja Secure Boot
   - epäonnistuneet päivitykset
5. **Lopetus:**
   - `S` = sysprep: tili User poistetaan, asiakas luo oman tilinsä ja kone sammuu.
   - `V` = valmis: kone jää tilille User.
   - `R` = avaa raportti.
   - Ilman virheitä valinta tapahtuu itsestään 2 min kuluttua.

`Q` keskeyttää työpöytävaiheen.

## Ajurit (`Drivers\`)

| Kansio | |
|---|---|
| `WinPE\` | Levyohjain (Intel VMD/RST, jos levyjä ei näy) ja verkkokortti asennusympäristöön |
| `_Kaikki\` | Lisätään jokaiseen asennukseen |
| `<Valmistaja>\<Malli>\` | Mallikohtaiset ajurit |
| `_Cache\` | Tikulla: Dell/HP/Lenovo-ajuripaketit, jotka haetaan automaattisesti levykuvan kirjoituksen aikana (vaatii WinPE:ssä verkkokaapelin tai USB-Ethernet-sovittimen) |

## Rajoitukset

- **Ei vielä ajettu oikealla laitteistolla.** Testaa ensin Hyper-V:ssä (Gen2-virtuaalikone, ISO) ja sen jälkeen yhdellä koneella kultakin valmistajalta.
- **Home Single Language -avain:** asennusta ei voi vaihtaa Home-versiosta. Raportti näyttää virheen, ja koneelle tarvitaan erillinen levykuva.
- **Tuki suorittimelle:** Windows 11 24H2+ vaatii SSE4.2:n ja POPCNT:n. Valikko varoittaa, jos ne puuttuvat.
- **Lisenssit:** ilman emolevyn avainta tai digitaalista lisenssiä Windows ei aktivoidu. Raportti näyttää tämän punaisella.

Ajuriluetteloiden lähteet ovat samat kuin [OSDCloudissa](https://github.com/OSDeploy/OSD).
