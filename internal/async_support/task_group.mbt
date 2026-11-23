///|
/// Return the operation's result after the group has joined its children.
pub async fn[X] with_group_result(run : async (@async.TaskGroup) -> X) -> X {
  let mut result : X? = None
  @async.with_task_group(async fn(group) { result = Some(run(group)) })
  result.unwrap()
}
