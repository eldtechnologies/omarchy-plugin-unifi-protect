# Demo images

Demo mode (`eld-unifi-protect demo on`) shows made-up cameras so the plugin
can be screenshotted, developed and tried without real footage. Each camera
uses the image here with the matching name (`.jpg`, `.jpeg`, `.png` or
`.webp`, 16:9); a missing one gets a plain placeholder.

The images are AI-generated and show no real place or person. Demo mode
blurs their top-left corner, where generated "camera" images tend to put a
vendor logo, so screenshots never suggest an official product. To
regenerate one, use its prompt with an image generator:

| File | Prompt |
|---|---|
| `driveway` | Security camera footage, wide-angle fisheye lens, mounted high on a house, looking down a paved driveway with a parked dark SUV, late afternoon light, slight lens distortion, realistic CCTV image quality, no text or timestamps |
| `front-door` | Doorbell camera view, wide-angle, a modern front porch with potted plants and a welcome mat, a delivery person holding a parcel approaching the door, daylight, realistic CCTV look, no text or timestamps |
| `garden` | Security camera footage, wide-angle, looking over a back garden with a lawn, patio furniture and a hedge, evening golden hour, realistic CCTV image quality, no text or timestamps |
| `garage` | Indoor security camera, high corner view of a tidy garage with bicycles on the wall, a workbench and shelves, cool white lighting, realistic CCTV look, no text or timestamps |
| `gate` | Security camera at night, infrared black-and-white image, looking at a metal driveway gate and a tiled path with a wall light, realistic night-vision CCTV look, no text or timestamps |
| `side-path` | Security camera footage, wide-angle, a narrow side path along a white house wall with bins and a gate, a person walking toward the camera, overcast daylight, realistic CCTV look, no text or timestamps |

`tools/screenshots.sh` turns demo mode on, captures the README screenshots
from the real UI, and turns it off again.
