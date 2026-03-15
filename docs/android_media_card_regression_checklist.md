# Android Media Card Regression Checklist

This checklist verifies media card lifecycle stability after unifying cleanup strategy in `audio_handler`.

## Test Environment
- Device: Android 12+ (at least one physical device preferred)
- Build: debug and release
- Setting: background play enabled

## Global Observations (for every case)
- Notification card appears when playback starts.
- Title/artwork/actions match current media.
- Card updates position while playing.
- Card does not stay stale after media owner is fully released.

## Case 1: Video Page Basic Flow
1. Open a normal video page and start playback.
2. Pause from in-app controls.
3. Resume from notification card.
4. Exit video page using back navigation.
Expected:
- Notification follows play/pause state correctly.
- On final page exit, card is removed.

## Case 2: Listen Mode Flow (Audio Page)
1. From video page enter listen mode.
2. Verify notification metadata switches to listen item.
3. Play next/previous from notification controls.
4. Exit listen page.
Expected:
- Controls work and map to list navigation.
- If no other playback owner remains, card is removed.
- If returning to an active video owner, card remains and continues updating.

## Case 3: Live Room Flow
1. Enter live room and start live playback.
2. Leave live room.
Expected:
- Notification is removed when live room owner is released.
- No stale card remains in quick settings.

## Case 4: Completion Strategy
1. Play a short video to completion in each repeat mode.
2. Repeat for listen mode completion.
Expected:
- If playback auto-continues (loop/list next), card stays and updates to next item.
- If playback does not continue, card is cleared by handler.

## Case 5: Background and Return
1. Start playback in video page.
2. Send app to background (home button), wait 10-30 seconds, reopen app.
3. Pause playback and keep app in background beyond grace period.
Expected:
- Background playback state is reflected by card.
- After paused grace release path, card is eventually removed if no active playback.

## Case 6: Task Removal
1. Start playback.
2. Open recent tasks and swipe app away.
Expected:
- `onTaskRemoved` path clears notification card.
- No lingering media session notification remains.

## Case 7: Multi-Owner Transition
1. Open video page and start playback.
2. Enter listen mode from the same content.
3. Exit listen mode and return to video page.
4. Exit video page.
Expected:
- Owner transition does not cause card flicker or stale state.
- Card remains while at least one owner is active.
- Card clears when final owner is released.

## Optional Debug Verification
- Enable handler lifecycle logs via `videoPlayerServiceHandler?.setLifecycleDebugLogEnabled(true)`.
- Confirm logs include owner attach/dispose count and completion decisions.
