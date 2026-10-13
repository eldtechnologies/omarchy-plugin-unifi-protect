# Demo images

Demo mode (`eld-unifi-protect demo on`) shows made-up cameras so the plugin
can be screenshotted, developed and tried without real footage. Each camera
uses the image here with the matching name (`.jpg`, `.jpeg`, `.png` or
`.webp`, 16:9); a missing one gets a plain placeholder.

The images are AI-generated and show no real place or person. Demo mode
blurs their top-left corner, where generated "camera" images tend to put a
vendor logo, so screenshots never suggest an official product.

What each shipped image shows. They were made with an AI image generator by
the plugin's author; some carry a made-up timestamp, and most have a
UniFi-style logo the generator drew in the top-left corner, which demo mode
blurs as described above. To replace one, generate a similar 16:9
security-camera scene:

| File | Shows |
|---|---|
| `driveway` | Wide-angle view down a concrete driveway with a parked dark SUV, daylight |
| `front-door` | Doorbell-style fisheye view of a porch with a stone wall, a lantern and a doormat, daylight |
| `garage` | High corner view of a garage with a parked car and shelves, night-vision blue tint |
| `garden` | View over a back garden with a lawn, a patio table and flower beds, daylight |
| `gate` | A metal gate in a rendered wall with a palm tree behind, sunny daylight |
| `side-path` | A gravel side path along a house wall and a wooden fence to a gate, daylight |

`tools/screenshots.sh [workspace]` turns demo mode on, captures the README
screenshots from the real UI on an empty workspace, and turns it off again.
