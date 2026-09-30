# W11AUTO

Windows 11 -asennustikku, jolla asentajan tarvitsee vain **valita levy**. Tämän jälkeen kaikki muu on automaattista:

- Windows asentuu.
- Kone päivittää itsensä ja käynnistyy uudelleen, kunnes päivityksiä ei ole jäljellä.
- Ajurit asennetaan.
- Lopuksi asentaja saa raportin näytölle ja Discordiin.

Tikku on suunniteltu kymmenien koneiden kuukausitahtiin: mediaan lisätään valmiiksi uusin kumulatiivinen päivitys, ja ladatut ajuripaketit tallentuvat tikulle välimuistiin.

## Näin se toimii

```
USB-käynnistys (WinPE)
 ├─ valikko: kone, emolevyn lisenssiavain, suorittimen tuki, levyt
 ├─ asentaja: levyn numero + vahvistus (S = sysprep päälle/pois)
 ├─ levy tyhjennetään → GPT/UEFI (tai MBR/BIOS) → levykuva kirjoitetaan (DISM)
 ├─ ajurit: USB:n Drivers-kansio + valmistajan ajuripaketti (Dell/HP/Lenovo, välimuisti tikulla)
 ├─ laitesalaus estetään, laitteistovaatimukset ohitetaan, ensikirjautumisen animaatio pois
 └─ "IRROTA USB-TIKKU" → kone käynnistyy uudelleen heti, kun tikku irrotetaan
Ensimmäinen käynnistys
 ├─ OOBE ohitetaan (suomi, FLE-aikavyöhyke, paikallinen tili User ilman salasanaa)
 └─ HP/Lenovo-ajuripaketti puretaan ja asennetaan
Työpöytä (W11AUTO-ikkuna)
 ├─ VAHTI: laturi + netti (ja kello). Puuttuu → punainen ikkuna, hiljainen äänimerkki,
 │         Wi-Fi-valinta, Discord-hälytys 5 min jälkeen. Jatkuu itsestään, kun kunnossa.
 ├─ emolevyn avain eri versiolle (esim. Pro) → versionvaihto (changepk) → aktivointi
 ├─ päivityssilmukka: haku → lataus → asennus → uudelleenkäynnistys, kunnes 0 jäljellä
 │   (laturi tarkistetaan ennen jokaista uudelleenkäynnistystä)
 ├─ Defenderin määritykset, Store-sovellukset
 ├─ tarkistukset: aktivointi, ajurittomat laitteet, akun kunto, levyn SMART, TPM/Secure Boot
 └─ RAPORTTI: näytölle + Discordiin (HTML-liite) → [Sysprep ja sammuta] / [Valmis]
```

**Kaksi lopputilaa:**

| | Sysprep | Ei sysprepiä |
|---|---|---|
| Asiakas saa | Puhtaan käyttöönoton: luo oman tilinsä, kieli ja yksityisyysasetukset valitaan itse | Valmiin työpöydän, tili `User` ilman salasanaa |
| Kone jää | Sammutettuna (sammunut kone = valmis) | Päälle, W11AUTO siivottu pois |

Sysprep valitaan WinPE-valikosta (`S`) tai loppunäytöltä. Oletus tulee asetuksesta `SysprepDefault`.

## Vaatimukset

**Rakennuskone (Windows 10/11, järjestelmänvalvoja):**
- [Windows ADK + WinPE-lisäosa](https://learn.microsoft.com/windows-hardware/get-started/adk-install), versio 10.1.26100.2454 tai uudempi
- Suomenkielinen Windows 11 -ISO (x64): [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11)
- USB-tikku, vähintään 16 Gt. **Suositus: 64 Gt USB 3**, koska ajuripaketit tallentuvat tikulle välimuistiin.

**Asennettava kone:** x64-suoritin, jossa on SSE4.2 ja POPCNT (käytännössä vuodesta 2009 alkaen). Valikko varoittaa, jos suoritin ei käy. TPM:ää ja Secure Bootia ei vaadita.

## Tikun rakentaminen

```powershell
# 1. Asetukset (kerran). config.json ei mene versionhallintaan.
Copy-Item config.example.json config.json
notepad config.json            # Discord-webhook ym.

# 2. Tikku: uusimmat päivitykset haetaan automaattisesti ja lisätään levykuvaan
.\Build-Media.ps1 -IsoPath D:\Win11_25H2_Finnish_x64.iso -DownloadUpdates

# Pelkkä skriptien tai asetusten päivitys valmiille tikulle (sekunteja):
.\Build-Media.ps1 -PayloadOnly

# Hyper-V-testauksen ISO:
.\Build-Media.ps1 -IsoPath D:\Win11.iso -Target Iso -ReuseImage
```

Rakennus kestää noin 30–60 min, josta suurin osa kuluu päivitysten lisäämiseen levykuvaan. **Rakenna tikku uudelleen joka kuukausi** Microsoftin päivityspäivän (kuun toinen tiistai) jälkeen, niin päivitystä valmiina mediassa ei tarvitse ladata koneelle.

| Parametri | Merkitys |
|---|---|
| `-DownloadUpdates` | Hakee uusimmat kumulatiiviset päivitykset (Windows + .NET) Microsoft Update Catalogista kansioon `Updates\` |
| `-EditionId` | `Core` = Home (oletus), `Professional` = Pro |
| `-BootEx` | Käynnistystiedostot allekirjoitetaan Windows UEFI CA 2023 -varmenteella. Käytä, jos kone ei käynnisty tikulta Secure Boot päällä (vanha varmenne mitätöity). |
| `-SkipResetBase` | Nopeampi rakennus, mutta isompi levykuva |
| `-ReuseImage` | Käyttää edellistä `out\install.wim`-levykuvaa (esim. ISO:n tekoon tai tikun kopiointiin) |
| `-UsbDiskNumber` | USB-levyn numero. Jos puuttuu, skripti kysyy sen. |

Jos Catalog-haku lakkaa toimimaan (Microsoft muuttaa sivua), lataa `.msu`-tiedostot käsin osoitteesta [catalog.update.microsoft.com](https://www.catalog.update.microsoft.com) kansioon `Updates\` ja jätä `-DownloadUpdates` pois.

## Asentajan työnkulku

1. Tikku kiinni ja käynnistys tikulta (F12, F9, F10 tai Esc koneesta riippuen).
2. Valikossa: levyn numero + Enter, sitten sama numero uudelleen + Enter.
3. Asennus kestää 3–6 min. Kun ruutu sanoo **IRROTA USB-TIKKU**, irrota tikku: kone käynnistyy itse ja tikku on vapaa seuraavalle koneelle.
4. Työpöydällä kytke laturi ja verkko, jos ikkuna pyytää. Päivitykset hoituvat itsestään.
5. Raportti tulee näytölle ja Discordiin.

Pikanäppäimet: WinPE-valikossa `C` = komentokehote, `Q` = sammuta. Työpöydällä `Ctrl+Shift+Q` keskeyttää W11AUTO:n, ja raportti lähetetään keskeneräisenä.

## Asetukset (`config.json`)

| Avain | Oletus | Merkitys |
|---|---|---|
| `DiscordWebhook` | `""` | Discord-kanavan webhook (Kanava → Asetukset → Integraatiot → Webhookit). Tyhjä = ei Discordia. |
| `SysprepDefault` | `false` | Sysprepin oletusvalinta WinPE-valikossa |
| `DriverPacks` | `true` | Dell/HP/Lenovo-ajuripakettien haku |
| `BootEx` | `false` | Asetetaan parametrilla `-BootEx` |
| `MaxUpdateRounds` | `12` | Päivityskierrosten yläraja (estää ikuisen silmukan) |
| `WaitAlertMinutes` | `5` | Kuinka pitkän odotuksen jälkeen Discordiin lähtee hälytys puuttuvasta laturista |
| `SoundVolumePercent` | `25` | Järjestelmän äänenvoimakkuus (hiljainen merkkiääni) |
| `FinalCountdownSec` | `120` | Kuinka pitkän ajan jälkeen loppunäyttö jatkaa itsestään. Virheiden kanssa jatkoa ei tehdä automaattisesti. |

**Tietoturva:** webhook on tikulla ja asennuksen ajan koneen `C:\W11AUTO`-kansiossa. W11AUTO poistaa kansion lopuksi. Jos tikku katoaa, luo webhook uudelleen Discordissa.

## Ajurit

Katso [`Drivers/README.md`](Drivers/README.md). Lyhyesti:
- **Levyjä ei näy valikossa** → Intel VMD/RST-ajuri kansioon `Drivers\WinPE` (tai VMD pois BIOSista).
- **Dell, HP ja Lenovo:** valmistajan ajuripaketti haetaan automaattisesti, kun WinPE:ssä on verkko. Wi-Fi ei toimi WinPE:ssä, joten käytä **USB-Ethernet-sovitinta**. Kerran ladattu paketti on tikulla, joten sama malli ei tarvitse verkkoa uudelleen.
- **Muut ajurit** tulevat Windows Updatesta päivityssilmukassa. Valinnaiset ajurit jätetään pois.

## Testaus Hyper-V:ssä (tee ennen ensimmäistä oikeaa konetta)

```powershell
.\Build-Media.ps1 -IsoPath D:\Win11.iso -Target Iso
New-VM -Name W11AUTO-test -Generation 2 -MemoryStartupBytes 4GB -NewVHDPath C:\VM\w11auto.vhdx -NewVHDSizeBytes 80GB -SwitchName 'Default Switch'
Add-VMDvdDrive -VMName W11AUTO-test -Path .\out\W11AUTO.iso
Set-VMFirmware -VMName W11AUTO-test -FirstBootDevice (Get-VMDvdDrive -VMName W11AUTO-test)
Set-VMKeyProtector -VMName W11AUTO-test -NewLocalKeyProtector; Enable-VMTPM -VMName W11AUTO-test
Checkpoint-VM -Name W11AUTO-test -SnapshotName tyhja
Start-VM W11AUTO-test; vmconnect localhost W11AUTO-test
```

Paina näppäintä, kun virtuaalikone käynnistyy ("Press any key to boot from CD or DVD"). Asennuksen jälkeen uudelleenkäynnistys tapahtuu 10 s kuluttua. DVD:n "Press any key" -kehote suojaa uudelleenasennukselta, kunhan et paina näppäintä. Testaa myös laturivahti: virtuaalikoneessa ei ole akkua, joten se menee läpi pöytäkoneena. Testaa verkkovahti irrottamalla virtuaalikytkin.

## Tunnetut rajoitukset ja riskit

- **Ei vielä testattu oikealla laitteistolla.** Skriptit on tarkistettu jäsentimellä ja PSScriptAnalyzerilla, ja ajuriluetteloiden jäsennys on testattu näyteaineistolla. Aja Hyper-V-testi ja yksi kone jokaiselta valmistajalta ennen tuotantoa.
- **Home Single Language:** jos emolevyn avain on "Home Single Language", Home-asennusta ei voi vaihtaa sille. Raportti näyttää virheen. Rakenna tarvittaessa toinen tikku: `-EditionId CoreSingleLanguage`.
- **Pro-avain:** Home vaihdetaan Proksi `changepk`-komennolla (1 lisäkäynnistys). Tämä on Microsoftin tuettu päivityspolku.
- **Laitteistovaatimusten ohitus:** koneet, jotka eivät täytä vaatimuksia, eivät välttämättä saa versiopäivityksiä Windows Updatesta. Raportti merkitsee ne keltaisella, jotta voit kertoa asiakkaalle.
- **Microsoft Update Catalog** jäsennetään HTML:stä (ei virallista API:a). Käsinlataus toimii varalla.
- **Home ohittaa ryhmäkäytännöt**, joten Windowsin oma automaattipäivitys voi kilpailla W11AUTO:n kanssa. Tämä on hoidettu uusintayrityksillä ("toinen asennus käynnissä").
- **Lisenssit:** yleinen Home-asennus ei aktivoidu ilman emolevyn avainta tai digitaalista lisenssiä. Raportti näyttää tämän punaisella. Jos myyt koneita, katso Microsoftin kunnostajaohjelma (Microsoft Registered Refurbisher).

## Lokit

| Missä | Mitä |
|---|---|
| Tikku: `W11AUTO\Logs\<sarjanumero>-<aika>.log` | WinPE-asennuksen loki |
| Kone: `C:\Windows\Logs\W11AUTO\` | `deploy.log`, `W11AUTO.log` (päivityskierrokset) ja HTML-raportti |

## Rakenne

```
Build-Media.ps1            tikun/ISO:n rakennus (Windows + ADK)
build/UpdateCatalog.psm1   päivitysten haku Catalogista
payload/WinPE/             startnet.cmd, Deploy.ps1 (valikko + asennus), DriverPacks.psm1
payload/Windows/           unattend.xml, Specialize.ps1, Start.ps1 (työpöytä), Updates/Report/UI/Common.psm1, Finalize.ps1 (sysprep)
Drivers/                   omat ajurit (WinPE, _Kaikki, valmistaja\malli)
Updates/                   .msu-paketit levykuvaan
```

Ajuripakettien luettelolähteet ja idea: [OSDCloud / OSD-moduuli](https://github.com/OSDeploy/OSD) (David Segura).
