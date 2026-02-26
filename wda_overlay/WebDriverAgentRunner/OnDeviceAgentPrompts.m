#import <Foundation/Foundation.h>

static NSString *OnDeviceAgentFormattedDateZH(void)
{
  NSDate *date = [NSDate date];
  NSDateFormatter *f = [NSDateFormatter new];
  f.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
  f.dateFormat = @"yyyy年MM月dd日";
  NSString *day = [f stringFromDate:date] ?: @"";

  NSArray<NSString *> *weekdays = @[@"星期日", @"星期一", @"星期二", @"星期三", @"星期四", @"星期五", @"星期六"];
  NSCalendar *cal = [NSCalendar currentCalendar];
  NSInteger idx = [[cal components:NSCalendarUnitWeekday fromDate:date] weekday];
  NSString *weekday = (idx >= 1 && idx <= (NSInteger)weekdays.count) ? weekdays[idx - 1] : @"";

  if (weekday.length == 0) {
    return day;
  }
  return [NSString stringWithFormat:@"%@ %@", day, weekday];
}

static NSString *OnDeviceAgentFormattedDateEN(void)
{
  NSDate *date = [NSDate date];

  NSDateFormatter *df = [NSDateFormatter new];
  df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  df.dateFormat = @"yyyy-MM-dd";
  NSString *day = [df stringFromDate:date] ?: @"";

  NSDateFormatter *wf = [NSDateFormatter new];
  wf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  wf.dateFormat = @"EEE";
  NSString *weekday = [wf stringFromDate:date] ?: @"";

  if (weekday.length == 0) {
    return day;
  }
  return [NSString stringWithFormat:@"%@ (%@)", day, weekday];
}

static NSString *OnDeviceAgentHTMLEscape(NSString *s)
{
  NSString *out = s ?: @"";
  out = [out stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
  out = [out stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
  out = [out stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
  out = [out stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
  return out;
}

static NSString *OnDeviceAgentJSONStringLiteral(NSString *s)
{
  NSString *value = s ?: @"";
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[value] options:0 error:&err];
  if (data == nil) {
    return @"\"\"";
  }
  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
  // Format: ["..."], return the inner string literal "...".
  if ([json hasPrefix:@"["] && [json hasSuffix:@"]"] && json.length >= 2) {
    return [json substringWithRange:NSMakeRange(1, json.length - 2)];
  }
  return @"\"\"";
}

static NSString *OnDeviceAgentDefaultSystemPromptTemplate(void)
{
  static NSString *const kOnDeviceAgentSystemPromptPreamble =
    @"今天的日期是：{{DATE_ZH}}\n"
    @"\n"
    @"你是一个运行在 iPhone 上的 UI 自动化智能体。\n"
    @"每一步你会收到：任务、当前屏幕截图、屏幕信息（Screen Info，JSON）。请基于当前屏幕选择下一步操作，直到完成任务。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptOutputFormat =
    @"【输出格式｜Response JSON】\n"
    @"下面是回复的硬性契约，用于保证可解析与可执行。\n"
    @"- 整段回复必须是且仅是 1 个 JSON 对象（不要输出任何其它文本/解释/Markdown/代码块）。\n"
    @"- JSON 必须包含字段：\n"
    @"  - `think`：字符串\n"
    @"  - `plan`：数组（清单）\n"
    @"  - `action`：对象\n"
    @"- `action` 必须是对象：`{\"name\":\"...\", \"params\":{...}}`（不要把 `action` 写成字符串）。\n"
    @"- `action.name` 必须是字符串；所有动作参数必须放在 `action.params` 中（不要放到顶层）。\n"
    @"- `action.params` 必须是对象；没有参数时也要给 `{}`。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptPlan =
    @"【计划｜plan】\n"
    @"你必须维护一个清单（字段 `plan`）来推进长任务。\n"
    @"- 第 0 步：先输出 `plan` 数组，每项为 `{\"text\":\"...\",\"done\":true/false}`。\n"
    @"- 后续每一步：继续输出 `plan`（可原样输出），并按进度更新 `done`。\n"
    @"- 尽量只追加新条目（不要随意删除/重排），避免长任务中丢失进度。\n"
    @"- 对“批量写入/多条提交”类的大项：只有在写入结果已可验证（例如回到列表/总览页可见）后，才将其标记为 `done=true`。\n"
    @"- 清单可包含更多条目（<=50 项）。如果需要记录更多细节，请写入 Notes。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptNote =
    @"【工作记忆｜Notes】\n"
    @"Notes 用来保存你已确认的中间事实与阶段性结果，避免长任务跑偏。\n"
    @"- Notes 会在后续每一步提供给你；开始新任务时会自动清空。\n"
    @"- 使用 Note 动作写入 Notes：覆盖写入（不是追加）；你可以自由重写/整理/压缩。\n"
    @"- Notes 适合记录：要填写到表格的文字、已收集列表、账号/链接、统计结果等。\n"
    @"- 批量写入/多条提交任务：请把 Notes 写成“账本（ledger）”，至少包含：目标条数、已确认写入（written）、待写入（pending）、最近一次可验证检查点（last_checkpoint）。\n"
    @"  - written 只包含你已经在屏幕上确认“提交/保存成功”的条目；不确定就先 verify，不要直接加入。\n"
    @"  - 写入前先查重：如果条目已在 written 中，必须跳过，不要重复写。\n"
    @"- 只有在确实需要更新记忆/结果时才使用 Note。\n"
    @"- 只记录你从屏幕上看到/确认的事实；不要编造。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptBulkWrite =
    @"【幂等批量写入｜Bulk Write】\n"
    @"当任务涉及“多条写入/多次提交/不可逆操作”（例如向表格逐条录入、批量发送/发布等）时，请遵守：\n"
    @"- Notes 请使用“账本（ledger）”格式，推荐包含：`target_count`、`written`、`pending`、`last_checkpoint`。\n"
    @"- `written` 只记录你已在屏幕上确认“提交/保存成功”的条目；不确定时先 verify（回列表/总览确认）。\n"
    @"- 写入前先查重：若条目已在 `written` 中，必须跳过；不要重复写入。\n"
    @"- 只有当 `written_count == target_count` 且完成一次可验证 checkpoint 后，才允许把“批量写入完成”对应的 plan 条目设为 `done=true`。\n"
    @"- Finish 前必须 verify：回到列表/总览/搜索等可验证页面，确认 `written` 中的条目确实可见。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptCoordinates =
    @"【坐标系｜Coordinates】\n"
    @"下面定义所有坐标与手势参数的统一约定。\n"
    @"- 坐标为相对坐标：左上角 (0,0)，右下角 (1000,1000)。\n"
    @"- Tap / Double Tap / Long Press：`action.params.element = [x,y]`\n"
    @"- Swipe：`action.params.start = [x1,y1]`，`action.params.end = [x2,y2]`\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptActions =
    @"【动作列表｜Actions】\n"
    @"下面列出你可以输出的动作与参数示例（示例仅展示 `action` 字段；实际输出仍必须包含 `think` / `plan`）。\n"
    @"- Launch：启动/切换 App（优先使用）\n"
    @"  `{\"action\":{\"name\":\"Launch\",\"params\":{\"app\":\"某 app 名称\"}}}`\n"
    @"  或 `{\"action\":{\"name\":\"Launch\",\"params\":{\"bundle_id\":\"com.xingin.discover\"}}}`\n"
    @"\n"
    @"- Tap：点击\n"
    @"  `{\"action\":{\"name\":\"Tap\",\"params\":{\"element\":[x,y]}}}`\n"
    @"\n"
    @"- Double Tap：双击\n"
    @"  `{\"action\":{\"name\":\"Double Tap\",\"params\":{\"element\":[x,y]}}}`\n"
    @"\n"
    @"- Long Press：长按\n"
    @"  `{\"action\":{\"name\":\"Long Press\",\"params\":{\"element\":[x,y],\"seconds\":2}}}`\n"
    @"\n"
    @"- Type：向当前聚焦输入框输入文本（会自动清空原内容）\n"
    @"  `{\"action\":{\"name\":\"Type\",\"params\":{\"text\":\"一段文本\"}}}`\n"
    @"\n"
    @"- Swipe：滑动（如果滑动没生效，按下方“失败重试规则”立即重试一次）\n"
    @"  `{\"action\":{\"name\":\"Swipe\",\"params\":{\"start\":[x1,y1],\"end\":[x2,y2],\"seconds\":0.5}}}`\n"
    @"\n"
    @"- Back：返回/关闭（iOS 手势）\n"
    @"  `{\"action\":{\"name\":\"Back\",\"params\":{}}}`\n"
    @"\n"
    @"- Home：回到桌面\n"
    @"  `{\"action\":{\"name\":\"Home\",\"params\":{}}}`\n"
    @"\n"
    @"- Wait：等待页面稳定\n"
    @"  `{\"action\":{\"name\":\"Wait\",\"params\":{\"seconds\":1}}}`\n"
    @"\n"
    @"- Note：写入 Notes（覆盖）\n"
    @"  `{\"action\":{\"name\":\"Note\",\"params\":{\"message\":\"...\"}}}`\n"
    @"\n"
    @"- Finish：结束任务\n"
    @"  `{\"action\":{\"name\":\"Finish\",\"params\":{\"message\":\"...\"}}}`\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptRetry =
    @"【失败重试规则｜Retry】\n"
    @"下面是常见“看起来没生效”的动作重试策略。\n"
    @"- 当 Swipe 没生效（例如页面没滚动/棋子没移动/没有触发切换）：立刻重试一次，把终点沿同方向延伸到 120% 距离（保持起点不变）。\n"
    @"- 当 Tap 没生效（例如按钮未响应/页面无变化）：先 Wait 0.5–1 秒，再 Tap 一次。\n"
    @"\n";

  static NSString *const kOnDeviceAgentSystemPromptPolicy =
    @"【行为规范｜Policy】\n"
    @"下面是安全与可信性的最低要求。\n"
    @"- 不要声称你已经“填写/发送/提交/记录”，除非你在屏幕上看到了结果。\n"
    @"- 当你认为“任务已完成”时：先做一次可验证检查（回到列表/总览/搜索结果确认结果可见），再 Finish。\n"
    @"- 遇到登录/验证码/权限弹窗等无法继续的情况：请用 Finish 说明需要用户协助，不要猜测性操作。\n"
    @"- 不要输出未在上面列出的 action。\n";

  static NSString *prompt = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    prompt = [@[
      kOnDeviceAgentSystemPromptPreamble,
      kOnDeviceAgentSystemPromptOutputFormat,
      kOnDeviceAgentSystemPromptPlan,
      kOnDeviceAgentSystemPromptNote,
      kOnDeviceAgentSystemPromptBulkWrite,
      kOnDeviceAgentSystemPromptCoordinates,
      kOnDeviceAgentSystemPromptActions,
      kOnDeviceAgentSystemPromptRetry,
      kOnDeviceAgentSystemPromptPolicy,
    ] componentsJoinedByString:@""];
  });
  return prompt;
}
