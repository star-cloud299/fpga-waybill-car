"""GUI result summaries must distinguish missing labels from failed processing."""

def completion_message(status,expected,rows,failure=None):
    if status=='FAIL':
        error=failure or next((r.get('error') for r in rows if r.get('error')),None)
        return '处理失败：'+(error or '未取得结果，请查看本次error.log和report.json')
    prefix='已取消后续模式' if status=='CANCELLED' else '流程完成'
    if not str(expected).strip():return prefix+'；未填写期望文本，未判定精确匹配'
    labeled=[r for r in rows if r.get('exact_match') is not None]
    if not labeled:return prefix+'；已填写期望文本，但尚无可判定的解码结果'
    correct=sum(r.get('exact_match') is True for r in labeled)
    return prefix+f'；精确匹配 {correct}/{len(labeled)} 个模式'
