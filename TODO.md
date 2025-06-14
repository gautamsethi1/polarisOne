# polarisOne To-Do List

## High Priority
- [ ] Fix oversized bounding box - implement dynamic subject-fitted box using actual body joint positions. But keep the movement on where the camera has to move, not where the subject needs to move. Ensure the bounding box only shows green when the subject is properly framed inside of the box
- [ ] Remove multiple directional circles causing visual clutter and confusion
- [ ] Implement new unified directional indicator system (Apple-style level or dynamic arrow)
- [ ] Fix false positive alignment - ensure green only shows when subject is properly framed inside of the box
- [ ] Calculate accurate subject bounds using visible joint positions with proper padding

## Medium Priority
- [ ] Design and implement edge-based alignment guides for subtle directional feedback
- [ ] Add haptic feedback system for alignment (different patterns for different axes)
- [ ] Ensure no UI elements overlap with camera controls

## Low Priority
- [ ] Modify API prompt to request exact magnitude values only (no ranges)
- [ ] Implement smooth animations between alignment states
- [ ] Add alignment percentage or score indicator
- [ ] Create adaptive UI that hides indicators when not needed

## Completed
<!-- Move completed items here -->