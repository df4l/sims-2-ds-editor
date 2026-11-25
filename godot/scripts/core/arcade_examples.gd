class_name ArcadeExamples
extends RefCounted
## Example arcade games in the arcade language (docs/formats/arcade_vm.md), offered by the Arcade tab as templates.

const LANDER := """; Lunar Lander: land gently on the pad.
; UP or B: thrust (uses fuel), LEFT / RIGHT: steer. B: play again. (A is taken by the Sims UI: it presses Stop.)
palette #000000, #FFFFFF, #FF8020, #60C0FF

sprite ship
......3333......
.....333333.....
....33.11.33....
....33.11.33....
.....333333.....
....3.3..3.3....
...3..3..3..3...
..33........33..
end

sprite flame
......2..2......
.......22.......
......2..2......
.......22.......
end

sprite wreck
................
....3.....3.....
..2...3.3...2...
.3..2.....2..3..
...3.2.3.2.3....
..3333.3.3333...
.33.3333333.33..
3333333333333333
end

const GRAV = 1          ; speeds in 1/16 pixel per frame
const THRUST = 3
const GROUND = 116

var x, y, vx, vy, fuel, padx, state   ; state: 0 flying, 1 landed, 2 crashed
keep best

func newround
  x = 16 * 16
  y = 10 * 16
  vx = 8
  vy = 0
  fuel = 300
  padx = 20 + rnd(80)
  state = 0
end

func init
  newround
end

func frame
  cls 0
  if attract
    title
    return
  end
  if state == 0
    fly
  elif pressed(B)
    newround
  end
  draw
end

func title
  text "LUNAR", 34, 30, 3, 3
  text "LANDER", 30, 50, 3, 3
  spr ship, 56, 80
  rect 0, GROUND, 128, 12, 1
  text "INSERT COIN", 42, 100, 2
end

func fly
  vy += GRAV
  if held(UP | B) and fuel > 0
    vy -= THRUST
    fuel -= 1
  end
  if held(LEFT)
    vx -= 1
  end
  if held(RIGHT)
    vx += 1
  end
  x += vx
  y += vy
  if x < 0
    x = 0
    vx = 0
  end
  if x > 112 * 16
    x = 112 * 16
    vx = 0
  end
  if y < 0
    y = 0
    vy = 0
  end
  if y / 16 + 8 >= GROUND
    y = (GROUND - 8) * 16
    if x / 16 >= padx - 2 and x / 16 + 16 <= padx + 22 and vy < 24 and abs(vx) < 8
      state = 1
      best = max(best, fuel)
      sfx SFX_CATCH
    else
      state = 2
      sfx SFX_EXPLODE
    end
  end
end

func draw
  rect 0, GROUND, 128, 12, 1
  rect padx, GROUND, 20, 2, 3
  text "FUEL", 2, 2, 1
  num fuel, 22, 2, 3
  text "BEST", 84, 2, 1
  num best, 104, 2, 3
  if state == 2
    spr wreck, x / 16, y / 16
    text "CRASHED!", 48, 50, 2
    text "B: AGAIN", 48, 60, 1
    return
  end
  spr ship, x / 16, y / 16
  if state == 0 and held(UP | B) and fuel > 0
    spr flame, x / 16, y / 16 + 8
  end
  if state == 1
    text "LANDED!", 50, 50, 3
    text "B: AGAIN", 48, 60, 1
  end
end
"""

const CARD := """; Test card: scrolling checker, colours inverted while a key is held.
palette #000000, #FF0000, #00FF00, #FFFFFF

var c, i, j

func frame
  for j = 0 to 7
    for i = 0 to 7
      c = (i + j + tick / 8) & 3
      if held(0xFFF)
        c ^= 3
      end
      rect i * 16, j * 16, 16, 16, c
    end
  end
  text "TEST CARD", 46, 60, 3
end
"""

const ALL := {"Lunar Lander": LANDER, "Test card": CARD}
