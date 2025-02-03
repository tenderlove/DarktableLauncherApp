# Darktable Launcher App

This is a very small app that adds an extension to the Photos app on macOS.
When you edit a photo in the Photos app, this extension lets you select
"Edit in darktable" and it will open the file in darktable for editing.

## Yes

This is probably my first serious app on macOS so there are definitely bugs
and I'm probably not doing everything correctly. Patches would be greatly
appreciated!

## Building

Theoretically, you can just do `xcodebuild`, then copy the app from the `build`
folder to your Applications folder and it should work (at least it seems to be
working for me).

## Good Stuff

This extension stores the XMP metadata in Photos. This means that your edits
are saved in the Photos app, and if you edit the photo again in darktable all
of your editing history will be available.

## Bad Stuff

The extension basically shells out to darktable for everything.  I think this
is fine, but since darktable has locks, you need to **make sure darktable is
closed before selecting "Edit in darktable"**.

I think it would be cool if there is a way to communicate with an open
darktable process and ask it to open a file. That functionality may exist, I
haven't done any research on it at this point.
