# Simple Godot Command Guide

These are the plain-language instructions we will use when working on the Android game.

| Command | Meaning |
| --- | --- |
| **Inspect** | Look at the current files or behavior before changing anything. |
| **Plan** | Describe the smallest safe implementation before editing. |
| **Build** | Implement the agreed feature. |
| **Test** | Run the project and check the feature. |
| **Device test** | Install and test an APK on an Android device. |
| **Fix** | Correct a specific problem without unrelated changes. |
| **Review** | Summarize changed files, behavior, and remaining risks. |
| **Commit** | Save a focused change to Git. |
| **Merge** | Integrate a reviewed pull request. |

## How to ask for a feature

Use a short request such as:

> Build: add touch camera panning.

I will explain what will change, keep the implementation focused, and report how to test it on Android.

## Godot Editor basics

- **Import:** open a project by selecting its `project.godot` file.
- **F5:** run the project's main scene in the editor.
- **Stop:** end the running game and return to the editor.

Editor runs help catch early issues, but Android device testing is required before we consider a mobile feature complete.
