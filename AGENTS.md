# Local app delivery

When the user requests an app change, finish by building and installing it with
`bash Scripts/install_local.sh release`. The app the user runs is
`/Applications/Boring Notch Octave.app`; editing source alone does not deliver
the change. Use the installer to preserve the local signing identity, archive
older copies, launch the installed app, and verify the running executable.
Report a build or installation failure explicitly instead of claiming the app
has been updated.
