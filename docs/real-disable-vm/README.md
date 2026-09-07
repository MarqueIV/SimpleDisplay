# Prueba del apagado real (`CGSConfigureDisplayEnabled`) en una VM Tart

Corrida el 2026-09-07 sobre la rama `feat/real-display-disable` (PR #1 de Kyle Fang +
arreglos de la review). VM `simpledisplay-real-disable`: clon de
`ghcr.io/cirruslabs/macos-tahoe-base:latest` (macOS 26.6.2, arm64, admin/admin) en el
`TART_HOME` por defecto del disco interno (`~/.tart`, APFS: el clon es instantaneo).
Build `make bundle` firmado ad hoc, desplegado con `docs/colorsync-stress/deploy.sh`.

Evidencia en esta carpeta:

- `test.sh` — guion host→guest: dispara `simpledisplay://...` por SSH, lee el JSON de
  `simpledisplay://status`, el log unificado de la app (`sudo log show`) y el estado
  persistido (`defaults export` + plistlib), y compara con `cgprobe`.
- `cgprobe.swift` — sonda CoreGraphics independiente de la app: lista online/activa,
  main, UUID, modo actual, modos disponibles y `CGDisplayGetDisplayIDFromUUID`.
- `run1-antes-de-fixes.log` — primera corrida: destapo dos bugs (abajo) y tenia errores
  propios del guion (formato de `defaults read`, siembra de fantasmas sin efecto).
- `run4-con-fixes.log` — primera tanda con el build corregido: **38 PASS, 0 FAIL**.
- `cgmirror.swift`, `cgmain.swift` — herramientas minimas (espejar / hacer main) para
  probar que tolera el WindowServer sin pasar por la app. Ver "Segunda tanda".
- `run7-headless-y-espejo.log` — segunda tanda (escenarios G y M): **65 PASS, 0 FAIL** (los 38 de la primera tanda mas 27 nuevos).
- `run8-serial-persistente-y-cli.log` — tercera tanda: serial persistente por virtual y
  subcomandos nuevos del CLI (`disable --headless`, `enable`, `mirror`, `unmirror`):
  **67 PASS, 0 FAIL**.

## Que puede y que no puede probar la VM

La VM tiene un solo display "fisico" (la consola, `Apple Virtual` 1920x1080). Los
monitores que se apagan y encienden son **displays virtuales de la propia app**
(`CGVirtualDisplay`), que para el WindowServer son displays como cualquier otro: el
apagado via `CGSConfigureDisplayEnabled`, la salida de la lista online, la transferencia
de main y la persistencia se ejercitan igual que con hardware. Lo que la VM **no**
reproduce:

- **Sleep/wake**: `pmset -g` reporta `sleep 0 (sleep prevented by powerd)`;
  `sudo pmset sleepnow` no hace nada. `handleWake` → `applyPersistedState` sigue sin
  probar en hardware.
- **Desconexion fisica** de un monitor apagado (se aproxima destruyendo un virtual apagado).
- Si un monitor real **entra en standby** al apagarlo, y como se ve la ventana de Tart al
  apagar la consola (nadie la miraba; CG confirmo la transferencia de main).
- Dos monitores fisicos identicos (se aproxima con dos virtuales del mismo nombre y
  distinto UUID, que es lo que importa para el cache de nombres por UUID).

## Escenarios y resultado (run 4)

| Esc. | Que hace | Resultado |
|---|---|---|
| S0/S1 | Reset de UserDefaults; crea `Twin`, `Twin` (1280x720) y `Retina` (1600x900 HiDPI) | 4 filas encendidas, Retina HiDPI |
| A | Apaga un Twin; el otro Twin conserva nombre y fila; reenciende | El apagado sale de `CGGetOnlineDisplayList` (CG), su fila queda como fantasma con nombre `Twin`; al encender vuelve online y activo |
| B | Apaga y enciende Retina | Vuelve **en HiDPI 1600x900** (restauracion de modo por UUID) |
| C | Apaga Retina, `pkill` + relanzar, enciende desde la fila fantasma | Tras relanzar Retina sigue apagada y fuera de la lista online (log: `Restored disabled state`); `enable?name=Retina` la trae de vuelta en HiDPI |
| D | Apaga Twin#2, lo **quita** (`remove`), relanza | La fila desaparece al quitarlo, la persistencia olvida su UUID, tras relanzar quedan 3 filas encendidas y **Retina conserva su UUID y 1600x900 HiDPI** (run 8; en runs 4-7 heredaba el slot de Twin#2, ver abajo) |
| H | Siembra en UserDefaults dos fantasmas de "una sesion previa": `Phantom` con `lastKnownID` = id vivo de la consola, `Orphan` con id 9999 | `Phantom` se descarta (log: `Dropping ghost row ... its retained ID 1 now belongs to ...`) y la consola **no** se toca; `Orphan` aparece como placeholder apagado y al intentar encenderlo se olvida (fila y flag) |
| E | Apaga el display **main** (la consola) | Main se transfiere a un virtual antes, la consola sale de la lista online; al encender vuelve y todo queda activo |
| F | `pmset sleepnow` | No soportado en la VM (INFO) |

## Hallazgos

### Bugs encontrados en la VM y corregidos (commit `fix: asentar antes de aplicar estado persistido...`)

1. **`applyPersistedState` decidia sobre una foto parcial.** Al arrancar, los displays
   virtuales restaurados todavia no estaban en la lista online cuando se leia
   `displays`, asi que un virtual persistido como apagado volvia **encendido** tras
   relanzar (run 1, escenario C: `FAIL Retina sigue apagada tras relanzar`). Ahora se
   espera `settleAndRefresh()` antes de decidir. En hardware el sintoma equivalente
   seria un monitor que tarda en aparecer al arrancar o al despertar.
2. **Quitar un virtual apagado dejaba rastro.** `removeVirtualDisplay` no limpiaba la
   fila fantasma ni el flag `isDisabled` persistido (run 1, escenario D: la fila muerta
   seguia listada hasta tocar el toggle). Como el UUID de un virtual deriva del **slot de
   serial reutilizable**, ese flag habria apagado al siguiente display que heredara el
   slot en el proximo arranque. Ahora `forgetDisabledState` reactiva el display, espera
   el asentamiento, descarta el fantasma y borra su entrada persistida
   (`DisplayStatePersistence.forget`). Tambien se aplica en `reconfigureVirtualDisplay`.

### Verificado de la review del PR

- `CGDisplayGetDisplayIDFromUUID` (header de ColorSync) funciona en Tahoe: devuelve el id
  actual para displays vivos y `0` para uno que ya no existe (`cgprobe ... resolve`).
  Sobre esto descansan la restauracion de modo por UUID y la readireccion de fantasmas.
- Colision de ID de un fantasma persistido: se descarta con warning y **no** se toca el
  display que ahora tiene ese ID. El flag persistido se conserva a proposito, para que
  el display se vuelva a apagar con un ID fresco si reaparece.
- Fantasma de un display inexistente: se muestra como placeholder y se olvida al fallar
  el encendido, con el mensaje localizado nuevo.
- HiDPI se restaura al reencender, incluso cuando el fantasma se reconstruyo tras
  relanzar la app (el fantasma conserva el modo vivo via `asDisabledGhost`).

### Preexistente en main, encontrado aqui y corregido en la tercera tanda

**Reasignacion del slot de serial + memoria de modo por identidad.** El N-esimo virtual
usaba el serial N (mas bajo libre) y al arrancar se restauraban en el orden guardado. Si se
quitaba un virtual intermedio y se relanzaba la app, el siguiente heredaba su slot y con el
la identidad (vendor/product/serial → UUID) y **el modo que macOS recuerda para esa
identidad**. En las corridas 4 a 7, tras quitar Twin#2 (slot 2, 1280x720) y relanzar,
`Retina` (configurada 1600x900 HiDPI, y asi la creaba la app segun su log) aparecia con el
UUID de Twin#2 y en **1280x720 sin HiDPI**; `cgprobe` mostraba que ese display ofrecia
tanto `1280x720` como `1600x900@2x` y macOS elegia el recordado. Sobrevivia a un reboot
del guest. Consecuencias: un virtual podia perder HiDPI tras un reinicio, y los flags
persistidos por UUID (apagado/main/espejo) de un virtual podian aplicarse a otro.

Arreglo (commit `fix: serial persistente por display virtual`): el serial se guarda en
`VirtualDisplayConfig.serial`; al restaurar, cada config recupera el suyo, y al reconfigurar
(quitar + recrear) se conserva. Un slot nuevo es el mas bajo que no este vivo **ni reservado
por otra config guardada**. Configs de versiones anteriores sin serial reciben uno en el
primer arranque y se re-guardan. Verificado en run 8: tras quitar Twin#2 y relanzar,
Retina conserva `E3BD08CD-…` y 1600x900 HiDPI. La acotacion de perfiles ColorSync se
mantiene (misma cantidad de identidades, ahora estables).

### Infraestructura de prueba

- El log unificado del guest solo muestra el subsistema `app.simpledisplay` con `sudo`.
- `defaults read` de un blob `-data` en Tahoe devuelve `{length = N, bytes = 0x...}`;
  `test.sh` usa `defaults export` + `plistlib`.
- `sshd` del guest rechaza el password a rachas (`opendirectoryd` al 24 % de CPU
  verificando logins en rafaga); `test.sh` reintenta cada SSH hasta 4 veces y fuerza
  `PubkeyAuthentication=no` para no agotar `MaxAuthTries` con llaves del host.
- La imagen base cacheada en `/Volumes/sam-ex/macOS-tart` (HFS+, 47 GB) se copio a
  `~/.tart/cache` (1 min) para clonar en APFS sin llenar el disco externo; el symlink
  `latest` del cache copiado apuntaba al disco externo y hubo que recrearlo.

## Segunda tanda (2026-09-07): ultimo display visible y espejo

Tras la primera tanda se agregaron dos features y se volvieron a probar en la misma VM:

- **Cuenta atras headless.** Apagar el ultimo display visible (quedan solo virtuales) se
  permite, pero un banner cuenta 15 s y lo vuelve a encender salvo que alguien pulse
  "Mantener apagado"; `simpledisplay://disable?...&headless=true` confirma de entrada.
  Solo un apagado confirmado se reaplica al arrancar; si la app muere durante la cuenta
  atras, al arrancar sin pantalla visible recupera el display y limpia el flag.
- **Espejo como accion aparte** (boton junto al toggle, `mirror`/`unmirror` por URL),
  persistido por UUID y reaplicado al arrancar; se disuelve antes de apagar un display
  que participe en el espejo, antes de destruir un virtual y antes de dormir.

### Escenarios nuevos (run 7)

| Esc. | Que hace | Resultado |
|---|---|---|
| G | Apaga la consola (unico fisico) con virtuales activos | Se apaga, `headless` no persistido, y **vuelve sola a los 15 s** |
| G | Idem con `headless=true`, espera 17 s, relanza | Queda apagada, persistido `headless=true`, sigue apagada tras relanzar; `enable` la trae de vuelta |
| G | Apaga la consola y mata la app durante la cuenta atras; relanza | Al arrancar sin pantalla visible y sin confirmacion, la consola se **recupera sola** y la persistencia queda limpia (log: `Recovered ...`) |
| M | `mirror` sobre un display **virtual** | Se rechaza con mensaje; el WindowServer sigue vivo |
| M | `mirror` sobre la consola (fisica) con main en un virtual | La consola espeja al main (`CGDisplayMirrorsDisplay` lo confirma), sigue encendida, persistido `mirrorOf`; tras relanzar el espejo se reaplica; `unmirror` la devuelve a 1920x1080 |
| M | Apagar el destino de un espejo | El espejo se disuelve primero (transaccion propia + asentamiento) y luego se apaga el destino; al encenderlo todo queda sin espejos |

### Hallazgo: un display virtual como esclavo de espejo crashea el WindowServer

En las corridas 5 y 6 el escenario M espejaba un virtual (que ademas era main) sobre la
consola. Resultado en ambas: la sonda paso a `online=0 active=0 main=0`, la app dejo de
responder y el PID del WindowServer cambio (`WindowServer[1641]` arrancando conexiones
justo despues del espejo): **crash del WindowServer y sesion nueva**. Separar la
transferencia de main y el espejo en transacciones con asentamiento (run 6) no cambio
nada, asi que se aislo el problema con `cgmirror`/`cgmain`, sin la app:

```
### E1 virtual->virtual: Retina(3) espeja a Twin(2)
complete: 0 (3 -> 2)
PROBE online=0 active=0 main=0
WindowServer pid=819 *** CRASH/RESTART ***        (antes: 176)

### E2 fisico->virtual: consola(1) espeja a Twin(2)   (main previamente en Twin)
complete: 0 (1 -> 2)
PROBE online=3 active=2 main=2
PROBE id=1 active=0 isActive=0 main=0 mirrorOf=2 ... 1280x720
WindowServer pid=173 OK
### E2 undo -> online=3 active=3, consola de vuelta en 1920x1080, mismo PID
```

Conclusion: `CGConfigureDisplayMirrorOfDisplay` con un `CGVirtualDisplay` como **esclavo**
tumba el WindowServer en macOS 26.6.2, sea el master fisico o virtual. Con un display
**fisico** como esclavo (master fisico o virtual) funciona, y el fisico adopta el modo del
master. Por eso la app solo ofrece el boton de espejo en filas fisicas y `mirror()`
rechaza virtuales aunque venga por URL. Es tambien el caso de uso remoto: el monitor
fisico espeja al virtual que ve remotedesk.

Nota operativa: tras un crash del WindowServer la sesion SSH deja de ver la sesion
grafica nueva (`open` falla con `OSLaunchdErrorDomain 125` y la sonda ve 0 displays);
hace falta reiniciar el guest.

### Otros ajustes de esta tanda

- `GhostReconciler` tambien resuelve fantasma contra fantasma: dos filas retenidas con el
  mismo ID (visto al sembrar un fantasma falso con el ID de la consola apagada) se
  reducen a una, prefiriendo la que resuelve por UUID.
- El guion busca el estado persistido por UUID, no por `lastKnownID`, y aborta M si el
  WindowServer se queda sin displays, para no encadenar fallos.

## Reproducir

```sh
# VM (una vez). Si la imagen esta cacheada solo en el disco externo, copiar el cache
# a ~/.tart/cache/OCIs/ghcr.io/cirruslabs/macos-tahoe-base y recrear el symlink `latest`.
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest simpledisplay-real-disable
tart set simpledisplay-real-disable --random-mac
tart run simpledisplay-real-disable &          # con ventana; --no-graphics deja al guest sin display
IP=$(tart ip simpledisplay-real-disable --wait 120)

# Build, deploy y sonda
make bundle && codesign --force --deep --sign - .build/SimpleDisplay.app
docs/colorsync-stress/deploy.sh $IP .build/SimpleDisplay.app .build/apple/Products/Release/simpledisplayctl
swiftc -O -target arm64-apple-macos14 docs/real-disable-vm/cgprobe.swift -o /tmp/cgprobe
sshpass -p admin scp -o StrictHostKeyChecking=no /tmp/cgprobe admin@$IP:/tmp/cgprobe

# Prueba (~4 min)
docs/real-disable-vm/test.sh $IP /tmp/real-disable.log
```

Esperado: `PASS=67 FAIL=0` y una linea `INFO` (`sleepnow` no soportado en la VM). Algunos
pasos van por `simpledisplayctl` (deploy.sh lo instala en `/usr/local/bin`) para cubrir el CLI.
