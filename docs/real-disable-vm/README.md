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
- `run4-con-fixes.log` — corrida final con el build corregido: **38 PASS, 0 FAIL**.

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
| D | Apaga Twin#2, lo **quita** (`remove`), relanza | La fila desaparece al quitarlo, la persistencia olvida su UUID, tras relanzar quedan 3 filas encendidas |
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

### Preexistente en main, **no corregido aqui** (fuera del alcance del PR)

**Reasignacion del slot de serial + memoria de modo por identidad.** El N-esimo virtual
usa el serial N (mas bajo libre) y al arrancar se restauran en el orden guardado. Si se
quita un virtual intermedio y se relanza la app, el siguiente hereda su slot y con el la
identidad (vendor/product/serial → UUID) y **el modo que macOS recuerda para esa
identidad**. En la prueba, tras quitar Twin#2 (slot 2, 1280x720) y relanzar, `Retina`
(configurada 1600x900 HiDPI, y asi la creo la app segun su log) aparecio con el UUID de
Twin#2 y en **1280x720 sin HiDPI**; `cgprobe` muestra que ese display ofrece tanto
`1280x720` como `1600x900@2x` y macOS eligio el recordado. Sobrevive a un reboot del
guest. Consecuencias: un virtual puede perder HiDPI tras un reinicio, y los flags
persistidos por UUID (apagado/main) de un virtual pueden aplicarse a otro.
Arreglo sugerido: persistir el serial en `VirtualDisplayConfig` para que la identidad no
migre, o reaplicar el modo configurado tras crear (`CGConfigureDisplayWithDisplayMode`).

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

Esperado: `PASS=38 FAIL=0` y dos lineas `INFO` (modo de Retina tras el relanzamiento de D,
y `sleepnow` no soportado).
