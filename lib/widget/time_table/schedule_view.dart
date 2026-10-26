/*
 *     Copyright (C) 2021  DanXi-Dev
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:dan_xi/generated/l10n.dart';
import 'package:dan_xi/model/time_table.dart';
import 'package:dan_xi/util/haptic_feedback_util.dart';
import 'package:dan_xi/widget/time_table/day_events.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_layout_grid/flutter_layout_grid.dart';
import 'package:intl/intl.dart';

double kRatio = 0.8;

/// A time table widget, usually used to show student's course schedule table.
class ScheduleView extends StatefulWidget {
  final List<DayEvents> laneEventsList;

  /// It is unused for now, do not rely on this to customize the style.
  final TimetableStyle timetableStyle;
  final TimeNow today;
  final int showingWeek;
  final OnTapCourseCallback? tapCallback;

  /// User notes keyed by course id, shown as an extra line on the course card.
  final Map<String, String>? courseNotes;

  /// Called when the user long-presses a block, drags it around and drops it
  /// into a free area. [day] is the lane index in [laneEventsList] and
  /// [firstSlot] is the new first slot of the block.
  final OnMoveCourseCallback? moveCallback;

  /// Called when the user long-presses a block and releases without dragging.
  final OnLongPressCourseCallback? longPressCallback;

  const ScheduleView(
      this.laneEventsList, this.timetableStyle, this.today, this.showingWeek,
      {super.key,
      this.tapCallback,
      this.courseNotes,
      this.moveCallback,
      this.longPressCallback});

  @override
  ScheduleViewState createState() => ScheduleViewState();
}

class ScheduleViewState extends State<ScheduleView> {
  int _maxSlot = 0;
  final GlobalKey _gridKey = GlobalKey();

  // ------- long-press drag session state -------
  ScheduleBlock? _draggingBlock;
  int? _dragOriginDay;
  int? _dragOriginFirstSlot;
  Offset? _dragStartGlobal;
  bool _dragMoved = false;
  Set<(int, int)>? _occupiedCells;
  (int, int)? _dropTarget;
  bool _dropTargetValid = false;
  double _cellWidth = 0, _rowHeight = 0;
  Offset _grabOffset = Offset.zero;
  Offset? _floatingCardGlobal;
  OverlayEntry? _dragOverlay;
  Timer? _autoScrollTimer;
  Offset? _lastPointerGlobal;

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _dragOverlay?.remove();
    _dragOverlay = null;
    super.dispose();
  }

  RenderBox? get _gridBox =>
      _gridKey.currentContext?.findRenderObject() as RenderBox?;

  /// Measure the actual grid size and derive the uniform cell geometry.
  ///
  /// Every cell in the grid (placeholders, time indicators and course blocks
  /// alike) is sized by the same [AspectRatio] ratio, so all columns share the
  /// same width and all rows share the same height.
  bool _measureGrid() {
    final box = _gridBox;
    if (box == null || !box.attached || box.size.width <= 0) return false;
    final int cols = widget.laneEventsList.length + 1;
    _cellWidth = box.size.width / cols;
    final double ratio = kRatio * (DateTime.daysPerWeek + 1) / cols;
    _rowHeight = _cellWidth / ratio;
    return true;
  }

  /// Map the top-left corner of the floating card to a (day, firstSlot) cell,
  /// clamped into the grid just like a home-screen icon.
  (int, int)? _cellForFloatingCard(Offset globalTopLeft, int span) {
    final box = _gridBox;
    if (box == null) return null;
    final local = box.globalToLocal(globalTopLeft);
    int day = (local.dx / _cellWidth).floor() - 1;
    day = day.clamp(0, widget.laneEventsList.length - 1).toInt();
    int firstSlot = ((local.dy - _rowHeight) / _rowHeight).round();
    firstSlot =
        firstSlot.clamp(0, max(0, _maxSlot - span + 1)).toInt();
    return (day, firstSlot);
  }

  void _startDrag(ScheduleBlock block, int day, Offset globalPosition) {
    if (!mounted || _draggingBlock != null) return;
    HapticFeedbackUtil.medium();
    _draggingBlock = block;
    _dragOriginDay = day;
    _dragOriginFirstSlot = block.firstSlot;
    _dragStartGlobal = globalPosition;
    _dragMoved = false;
    if (!_measureGrid()) {
      _draggingBlock = null;
      return;
    }
    // Cells occupied by other courses (the dragged block may return to them).
    _occupiedCells = {};
    for (int d = 0; d < widget.laneEventsList.length; d++) {
      for (final event in widget.laneEventsList[d].events) {
        if (!block.event.contains(event)) {
          _occupiedCells!.add((d, event.time.slot));
        }
      }
    }
    // Grab the block where the finger touched it, so the card lifts in place
    // and follows the finger 1:1, like a home-screen icon.
    final Offset originTopLeft = Offset(
        (1 + day) * _cellWidth + 2, (block.firstSlot + 1) * _rowHeight + 2);
    _grabOffset = globalPosition - originTopLeft;
    _dropTarget = (day, block.firstSlot);
    _dropTargetValid = true;
    _updateDragFromPointer(globalPosition);
    _dragOverlay = OverlayEntry(builder: (_) => _buildFloatingCard());
    Overlay.of(context, rootOverlay: true).insert(_dragOverlay!);
    _startAutoScroll();
    setState(() {});
  }

  void _updateDragFromPointer(Offset globalPointer) {
    if (_draggingBlock == null || !mounted) return;
    _lastPointerGlobal = globalPointer;
    _measureGrid();
    final int span = _draggingBlock!.slotSpan;
    // The card follows the finger with the offset it was grabbed at.
    final topLeft = globalPointer - _grabOffset;
    _floatingCardGlobal = topLeft;
    final target = _cellForFloatingCard(topLeft, span);
    if (target == null) return;
    if (_dropTarget != target) {
      final (day, firstSlot) = target;
      bool valid = true;
      for (int s = 0; s < span; s++) {
        if (_occupiedCells!.contains((day, firstSlot + s))) {
          valid = false;
          break;
        }
      }
      if (valid != _dropTargetValid) HapticFeedbackUtil.light();
      _dropTarget = target;
      _dropTargetValid = valid;
      setState(() {});
    }
    _dragOverlay?.markNeedsBuild();
  }

  void _onDragUpdate(LongPressMoveUpdateDetails details) {
    if (_draggingBlock == null) return;
    if ((details.globalPosition - _dragStartGlobal!).distance > 8) {
      _dragMoved = true;
    }
    _updateDragFromPointer(details.globalPosition);
  }

  void _onDragEnd(LongPressEndDetails details) {
    final block = _draggingBlock;
    final int? originDay = _dragOriginDay;
    if (block == null || originDay == null) return;
    final bool moved = _dragMoved &&
        (details.globalPosition - _dragStartGlobal!).distance > 8;
    final (int, int)? target = _dropTarget;
    final bool targetValid = _dropTargetValid;
    _stopDrag();
    if (!moved) {
      widget.longPressCallback?.call(block, originDay);
    } else if (targetValid &&
        target != null &&
        target != (originDay, block.firstSlot)) {
      final (day, firstSlot) = target;
      widget.moveCallback?.call(block, day, firstSlot);
    }
  }

  void _onDragCancel() => _stopDrag();

  void _stopDrag() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _dragOverlay?.remove();
    _dragOverlay = null;
    _draggingBlock = null;
    _dragOriginDay = null;
    _dragOriginFirstSlot = null;
    _dropTarget = null;
    _dropTargetValid = false;
    _occupiedCells = null;
    _dragStartGlobal = null;
    _lastPointerGlobal = null;
    _floatingCardGlobal = null;
    if (mounted) setState(() {});
  }

  /// Scroll the enclosing list when the finger stays near the screen edges,
  /// like dragging an app icon across home-screen pages.
  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_draggingBlock == null || _lastPointerGlobal == null || !mounted) {
        return;
      }
      final scrollable = Scrollable.maybeOf(context);
      if (scrollable == null) return;
      final position = scrollable.position;
      final double screenHeight = MediaQuery.of(context).size.height;
      const double edge = 96;
      final double y = _lastPointerGlobal!.dy;
      double? delta;
      if (y < edge) {
        delta = -(edge - y) / edge * 18;
      } else if (y > screenHeight - edge) {
        delta = (y - (screenHeight - edge)) / edge * 18;
      }
      if (delta == null) return;
      final double target = (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (target != position.pixels) {
        position.jumpTo(target);
        _updateDragFromPointer(_lastPointerGlobal!);
      }
    });
  }

  Widget _buildFloatingCard() {
    final block = _draggingBlock;
    if (block == null) return const SizedBox.shrink();
    final course = block.event.first.course;
    final bool multipleCourses =
        block.event.map((e) => e.course).toSet().length > 1;
    final String? note = multipleCourses
        ? null
        : (widget.courseNotes?[course.courseId]);
    final double cardWidth = _cellWidth - 4;
    final double cardHeight = block.slotSpan * _rowHeight - 4;
    return Positioned(
      left: _floatingCardGlobal?.dx ?? -1000,
      top: _floatingCardGlobal?.dy ?? -1000,
      width: cardWidth > 0 ? cardWidth : 1,
      height: cardHeight > 0 ? cardHeight : 1,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: Transform.scale(
            scale: 1.04,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 14,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: _buildCourseBody(course, enabled: true, note: note),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget table;
    for (var laneEvent in widget.laneEventsList) {
      for (var event in laneEvent.events) {
        _maxSlot = max(_maxSlot, event.time.slot);
      }
    }
    int cols = widget.laneEventsList.length + 1, rows = _maxSlot + 2;
    table = LayoutGrid(
      key: _gridKey,
      columnSizes: List.filled(cols, 1.fr),
      rowSizes: List.filled(rows, auto),
      children: _buildTable(cols, rows),
    );
    Widget result = MediaQuery.removePadding(
        context: context, removeTop: true, child: table);
    if (_draggingBlock != null && _dropTarget != null && _cellWidth > 0) {
      final (day, firstSlot) = _dropTarget!;
      final int span = _draggingBlock!.slotSpan;
      final Color base =
          _dropTargetValid ? Theme.of(context).colorScheme.secondary : Theme.of(context).colorScheme.error;
      result = Stack(
        clipBehavior: Clip.none,
        children: [
          result,
          Positioned(
            left: (1 + day) * _cellWidth + 2,
            top: (firstSlot + 1) * _rowHeight + 2,
            width: _cellWidth - 4,
            height: span * _rowHeight - 4,
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                decoration: BoxDecoration(
                  color: base.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: base.withValues(alpha: 0.9), width: 1.5),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return result;
  }

  List<Widget> _buildTable(int cols, int rows) {
    double ratio = kRatio * (DateTime.daysPerWeek + 1) / cols;

    List<Widget?> result = List.generate(
        cols * rows,
        (index) => Container(
              margin: const EdgeInsets.all(2),
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                  color: Theme.of(context).hintColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4)),
            ).withRatio(ratio).withGridPlacement(
                rowStart: index ~/ cols, columnStart: index % cols));

    // Build corner
    result[0] = const SizedBox()
        .withRatio(ratio)
        .withGridPlacement(columnStart: 0, rowStart: 0);

    // Build time indicator
    for (int slot = 0; slot <= _maxSlot; slot++) {
      String startTime = DateFormat("HH:mm")
          .format(TimeTable.kCourseSlotStartTime[slot].toExactTime());
      String endTime = DateFormat("HH:mm").format(TimeTable
          .kCourseSlotStartTime[slot]
          .toExactTime()
          .add(const Duration(minutes: TimeTable.MINUTES_OF_COURSE)));
      result[cols * (slot + 1)] = Center(
          child: Column(
        children: [
          Text((slot + 1).toString()),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              startTime,
              style:
                  TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
            ),
          ),
          Text(
            endTime,
            style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
          )
        ],
      )).withRatio(ratio).withGridPlacement(columnStart: 0, rowStart: slot + 1);
    }

    // Build day indicator & courses
    for (int day = 0; day < widget.laneEventsList.length; day++) {
      int deltaDay = widget.laneEventsList[day].weekday -
          widget.today.weekday +
          (widget.showingWeek - widget.today.week) * 7;
      DateTime date = DateTime.now().add(Duration(days: deltaDay));
      TextStyle highlightStyle =
          TextStyle(color: Theme.of(context).colorScheme.secondary);
      // Build weekday indicators
      result[1 + day] = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            deltaDay == 0
                ? Text(
                    widget.laneEventsList[day].day,
                    style: highlightStyle,
                  )
                : Text(
                    widget.laneEventsList[day].day,
                  ),
            deltaDay == 0
                ? Text(
                    DateFormat.Md().format(date),
                    style: highlightStyle,
                  )
                : Text(DateFormat.Md().format(date))
          ],
        ),
      ).withRatio(ratio).withGridPlacement(columnStart: day + 1, rowStart: 0);

      convertToBlock(widget.laneEventsList[day].events).forEach((element) {
        // While dragging, the lifted block leaves a gap at its origin.
        final bool isDragOrigin = _draggingBlock != null &&
            _dragOriginDay == day &&
            _dragOriginFirstSlot == element.firstSlot &&
            _draggingBlock!.slotSpan == element.slotSpan;
        // Keep the gesture detector alive at the origin cell even though its
        // content is replaced by a placeholder, so the in-flight long-press
        // drag keeps receiving pointer events across rebuilds.
        Widget cell = isDragOrigin ? _emptyCell() : _buildScheduleBlock(element);
        result[1 + day + cols * (element.firstSlot + 1)] =
            _wrapDragTarget(cell, element, day)
                .withRatio(ratio / element.slotSpan)
                .withGridPlacement(
                    columnStart: 1 + day,
                    rowStart: element.firstSlot + 1,
                    rowSpan: element.slotSpan);
        for (int j = 1; j < element.slotSpan; j++) {
          result[1 + day + cols * (element.firstSlot + 1 + j)] = null;
        }
      });
    }
    result.removeWhere((element) => element == null);
    return result.map((e) => e!).toList();
  }

  List<ScheduleBlock> convertToBlock(List<Event> list) {
    List<ScheduleBlock> result = list.map((e) => ScheduleBlock(e)).toList();
    bool flag = true;

    bool isSameCourse(Course a, Course b) {
      if (a.courseName != b.courseName || a.roomName != b.roomName) {
        return false;
      }
      return listEquals(a.teacherNames, b.teacherNames);
    }

    while (flag) {
      flag = false;
      for (int i = 0; i < result.length;) {
        try {
          ScheduleBlock neighboringBlock = result.firstWhere((element) {
            int startSlot = element.firstSlot;
            int endSlot = startSlot + element.slotSpan;

            return isSameCourse(
                    element.event.first.course, result[i].event.first.course) &&
                ((result[i].firstSlot + result[i].slotSpan == startSlot) ||
                    (result[i].firstSlot == endSlot));
          });
          flag = true;
          ScheduleBlock thisBlock = result.removeAt(i);
          neighboringBlock.firstSlot =
              min(thisBlock.firstSlot, neighboringBlock.firstSlot);
          neighboringBlock.slotSpan += thisBlock.slotSpan;
          // The event lists must grow with the span as well, otherwise a
          // merged block only remembers the events of its last part.
          neighboringBlock.event.addAll(thisBlock.event);
          neighboringBlock.event
              .sort((a, b) => a.time.slot.compareTo(b.time.slot));
        } catch (e) {
          ++i;
        }
      }
    }
    // Merge courses at the same time
    flag = true;
    while (flag) {
      flag = false;
      for (int i = 0; i < result.length;) {
        try {
          ScheduleBlock overlapBlock =
              result.sublist(i + 1).firstWhere((element) {
            return element.slotSpan == result[i].slotSpan &&
                element.firstSlot == result[i].firstSlot;
          });
          flag = true;
          ScheduleBlock thisBlock = result.removeAt(i);
          overlapBlock.event.addAll(thisBlock.event);
        } catch (e) {
          ++i;
        }
      }
    }

    // Change the order of courses at the same time to ensure that the first course should be
    // enabled if possible.
    for (ScheduleBlock block in result) {
      // Skip blocks that needn't be reordered
      if (block.event.first.enabled ||
          block.event.every((element) => !element.enabled)) {
        continue;
      }

      Event firstEnabledCourse =
          block.event.firstWhere((element) => element.enabled);
      block.event.remove(firstEnabledCourse);
      block.event.insert(0, firstEnabledCourse);
    }
    return result;
  }

  Widget _emptyCell() => Container(
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
            color: Theme.of(context).hintColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(4)),
      );

  Widget _wrapDragTarget(Widget child, ScheduleBlock block, int day) {
    final bool canDrag =
        widget.moveCallback != null || widget.longPressCallback != null;
    return GestureDetector(
      onLongPressStart:
          canDrag ? (d) => _startDrag(block, day, d.globalPosition) : null,
      onLongPressMoveUpdate: _onDragUpdate,
      onLongPressEnd: _onDragEnd,
      onLongPressCancel: _onDragCancel,
      child: child,
    );
  }

  Widget _buildScheduleBlock(ScheduleBlock block) {
    Widget body;
    // A block can contain several overlapping courses; only then the name
    // gets an "and more" suffix. A single course spanning several slots
    // (which happens since adjacent blocks merge their event lists) is
    // displayed plainly.
    final bool multipleCourses =
        block.event.map((e) => e.course).toSet().length > 1;
    if (multipleCourses) {
      Course copiedCourse =
          Course.fromJson(jsonDecode(jsonEncode(block.event.first.course)));
      copiedCourse.courseName = copiedCourse.courseName! + S.current.and_more;
      body = _buildCourseBody(copiedCourse, enabled: block.event.first.enabled);
    } else {
      final course = block.event.first.course;
      body = _buildCourseBody(course,
          enabled: block.event.first.enabled,
          note: widget.courseNotes?[course.courseId]);
    }
    return InkWell(
      onTap: () => widget.tapCallback?.call(block),
      child: body,
    );
  }

  Widget _buildCourseBody(Course course,
      {bool enabled = true, String? note}) {
    final TextStyle? textStyle = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(
            color: Theme.of(context).colorScheme.secondary.computeLuminance() >=
                    0.5
                ? Colors.black
                : Colors.white);
    return Container(
      margin: const EdgeInsets.all(2),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
          color: enabled
              ? Theme.of(context).colorScheme.secondary
              : Theme.of(context).hintColor,
          borderRadius: BorderRadius.circular(2)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(
            height: 2,
          ),
          AutoSizeText(course.courseName!,
              minFontSize: 12,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: textStyle?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(
            height: 4,
          ),
          AutoSizeText(course.roomName ?? "",
              minFontSize: 10, style: textStyle),
          if (note != null && note.isNotEmpty)
            AutoSizeText(note,
                minFontSize: 8,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textStyle?.copyWith(fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }
}

extension WidgetEx on Widget {
  Widget withRatio(double aspectRatio) => AspectRatio(
        aspectRatio: aspectRatio,
        child: this,
      );
}

class ScheduleBlock {
  int slotSpan = 1;
  late int firstSlot;
  late List<Event> event;

  ScheduleBlock(Event event) {
    this.event = [event];
    firstSlot = event.time.slot;
  }
}

class TimetableStyle {
  final int startHour;

  final int endHour;

  final Color laneColor;

  final Color cornerColor;

  final Color timeItemTextColor;

  final Color timelineColor;

  final Color timelineItemColor;

  final Color mainBackgroundColor;

  final Color timelineBorderColor;

  final Color decorationLineBorderColor;

  final double laneWidth;

  final double laneHeight;

  final double timeItemHeight;

  final double timeItemWidth;

  final double decorationLineHeight;

  final double decorationLineDashWidth;

  final double decorationLineDashSpaceWidth;

  final bool visibleTimeBorder;

  final bool visibleDecorationBorder;

  const TimetableStyle({
    this.startHour = 0,
    this.endHour = 24,
    this.laneColor = Colors.white,
    this.cornerColor = Colors.white,
    this.timelineColor = Colors.white,
    this.timelineItemColor = Colors.white,
    this.mainBackgroundColor = Colors.white,
    this.decorationLineBorderColor = const Color(0x1A000000),
    this.timelineBorderColor = const Color(0x1A000000),
    this.timeItemTextColor = Colors.blue,
    this.laneWidth = 300,
    this.laneHeight = 70,
    this.timeItemHeight = 60,
    this.timeItemWidth = 70,
    this.decorationLineHeight = 20,
    this.decorationLineDashWidth = 9,
    this.decorationLineDashSpaceWidth = 4,
    this.visibleTimeBorder = true,
    this.visibleDecorationBorder = false,
  });
}

typedef OnTapCourseCallback = void Function(ScheduleBlock block);

/// [day] is the lane index in [ScheduleView.laneEventsList] and [firstSlot]
/// is the new first slot the block was dropped at.
typedef OnMoveCourseCallback = void Function(
    ScheduleBlock block, int day, int firstSlot);

typedef OnLongPressCourseCallback = void Function(ScheduleBlock block, int day);
