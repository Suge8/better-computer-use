# A Tk window with one card on a canvas. Tk takes the location of a click from the hardware
# pointer, not from the event, so an event posted to its pid lands wherever the real pointer
# is. Clicking the card appends `card` to the log file given as the first argument, any other
# click `miss <x>,<y>` (canvas coordinates); the second argument is the window title. It
# prints `ready <Tk version>` once the window is on screen.
import sys
import tkinter

log, title = sys.argv[1], sys.argv[2]


def append(line):
    with open(log, "a") as handle:
        handle.write(line + "\n")


root = tkinter.Tk()
root.title(title)
root.geometry("+200+150")
canvas = tkinter.Canvas(root, width=420, height=220, bg="white", highlightthickness=0)
canvas.pack()
canvas.create_rectangle(120, 70, 300, 150, fill="#cfe3ff", outline="#336", tags="card")
canvas.create_text(210, 110, text="Card", font=("Helvetica", 36), tags="card")
canvas.tag_bind("card", "<Button-1>", lambda event: append("card"))
canvas.bind("<Button-1>", lambda event: None if canvas.find_withtag("current") else append(f"miss {event.x},{event.y}"))
root.after(300, lambda: print("ready", root.tk.call("info", "patchlevel"), flush=True))
root.mainloop()
