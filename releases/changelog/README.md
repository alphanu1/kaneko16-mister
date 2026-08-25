# Release changelogs

One file per released bitstream, named after it. `UNRELEASED.md` is the one
being written for whatever ships next; it is renamed to match the `.rbf` at the
moment that build is promoted into `releases/`.

These are written for the people who download the core, not for this
repository. That means:

- what CHANGED for someone playing it, not which module was edited
- a game named in every entry that is specific to one
- measurements where they make the claim checkable, because "sound is better"
  is not something a reader can verify and "the write rate went from 120 a
  frame to MAME's 15" is
- known issues carried forward until they are actually fixed

`docs/findings.md` is the other half of the record and has the reasoning, the
wrong turns and the numbers. A changelog entry that needs a paragraph of
explanation belongs there with a pointer from here.

Nothing enters a changelog for a build that has not been played on hardware --
the same rule the bitstreams themselves follow.
