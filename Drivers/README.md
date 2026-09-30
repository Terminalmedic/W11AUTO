# Ajurit

| Kansio | Käyttö |
|---|---|
| `WinPE\` | Ajurit, joita **asennusympäristö** tarvitsee: levyohjain (esim. Intel RST/VMD, jos levyjä ei näy valikossa) ja verkkokortti. Ladataan WinPE:hen käynnistyksessä (`drvload`) ja lisätään `boot.wim`:iin rakennettaessa. |
| `_Kaikki\` | Ajurit, jotka lisätään **jokaiseen** asennukseen. |
| `<Valmistaja>\<Malli>\` | Mallikohtaiset ajurit. Nimet kuten WMI ne antaa, esim. `Dell Inc.\Latitude 5420` tai `LENOVO\20W0S00000`. |
| `_Cache\` | (vain tikulla) W11AUTO tallentaa tänne ladatut Dell-, HP- ja Lenovo-ajuripaketit. Seuraava saman mallin kone ei lataa pakettia uudelleen. |

Kaikki alikansiot käydään läpi rekursiivisesti, ja mukaan otetaan `.inf`-tiedostot.
