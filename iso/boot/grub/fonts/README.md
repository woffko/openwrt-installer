# Hellforge GRUB Font

`hellforge.pf2` contains only ASCII `0x20-0x7e` glyphs generated from
DejaVu Sans Mono. It is used by GRUB `gfxterm` before Linux starts.

Generation command:

```sh
grub-mkfont --no-hinting --range=0x20-0x7e --size=16 \
  --name=HellforgeMono --output=hellforge.pf2 DejaVuSansMono.ttf
```

Expected SHA-256:

```text
28ac89d2977d68116093d696d50819abbd0125ddd4c25d3967583cace96c232a
```

The source font is distributed under the Bitstream Vera license; see
`LICENSE-DejaVu.txt`.
