'use strict';
'require view';
'require rpc';
'require ui';

var callGetStatus = rpc.declare({
	object: 'ipv6prefixsnat',
	method: 'get_status',
	expect: {}
});

var callGetCurrentRules = rpc.declare({
	object: 'ipv6prefixsnat',
	method: 'get_current_rules',
	expect: {}
});

var callTestRuntime = rpc.declare({
	object: 'ipv6prefixsnat',
	method: 'test_runtime',
	params: [ 'enabled' ],
	expect: {}
});

var callSetConfig = rpc.declare({
	object: 'ipv6prefixsnat',
	method: 'set_config',
	params: [ 'enabled' ],
	expect: { '': {} }
});

var callApply = rpc.declare({
	object: 'ipv6prefixsnat',
	method: 'apply',
	expect: { '': {} }
});

var callDisable = rpc.declare({
	object: 'ipv6prefixsnat',
	method: 'disable',
	expect: { '': {} }
});

var callReloadRuntime = rpc.declare({
	object: 'ipv6prefixsnat',
	method: 'reload_runtime',
	expect: { '': {} }
});

function notify(msg, type) {
	ui.addNotification(null, E('p', { 'class': type || '' }, [ msg ]));
}

function notifyRpcReply(resp, successFallback, failureFallback) {
	var ok = !!(resp && resp.ok === true);
	notify(formatRpcReply(resp, ok ? successFallback : failureFallback), ok ? '' : 'warning');
	return ok;
}

function formatRpcError(action, err) {
	var detail = (err && err.message) ? err.message : String(err);
	return _('%s 失败：%s').format(action, detail);
}

function formatRuleSource(source) {
	switch (source) {
	case 'nft_runtime':
		return _('nft 运行表');
	case 'rule_file':
		return _('规则文件');
	case 'none':
		return _('无');
	default:
		return source || _('未知');
	}
}

function formatRpcCode(code, fallback) {
	switch (code) {
	case 'STATUS_READ':
		return _('状态已读取');
	case 'CURRENT_RULES_READ':
		return _('当前规则已读取');
	case 'RUNTIME_TESTED':
		return _('运行时预检已完成');
	case 'CONFIG_SAVED':
		return _('配置已保存');
	case 'RULES_APPLIED':
		return _('规则已应用');
	case 'RULES_DISABLED':
		return _('已停用并移除规则');
	case 'RUNTIME_RELOADED':
		return _('已重新检测并重建规则');
	case 'CONFIG_SAVE_FAILED':
		return _('保存配置失败');
	case 'APPLY_FAILED':
		return _('应用规则失败');
	case 'DISABLE_FAILED':
		return _('停用并移除规则失败');
	case 'RUNTIME_RELOAD_FAILED':
		return _('重新检测并重建失败');
	case 'RUNTIME_TEST_FAILED':
		return _('运行时预检失败');
	case 'UNKNOWN_METHOD':
		return _('未知方法');
	default:
		return fallback || code || _('未知状态');
	}
}

function formatReasonCode(reasonCode, fallback) {
	if (reasonCode === '' || reasonCode === null || typeof reasonCode === 'undefined')
		return fallback || '';

	switch (reasonCode) {
	case 'INVALID_JSON_INPUT':
		return _('输入 JSON 无效');
	case 'UCI_SET_ENABLED_FAILED':
		return _('设置启用状态失败');
	case 'UCI_COMMIT_FAILED':
		return _('提交 UCI 配置失败');
	case 'FW4_AUTO_INCLUDES_DISABLED':
		return _('firewall.@defaults[0].auto_includes 未启用');
	case 'NEED_AT_LEAST_2_ACTIVE_IPV6_INTERFACES':
		return _('至少需要 2 个有效的活动 IPv6 接口');
	case 'NO_VALID_RULES_GENERATED':
		return _('未生成任何有效规则');
	case 'PREVIEW_NOT_READY':
		return _('当前环境尚不满足生成条件');
	case 'RULE_FILE_WRITE_FAILED':
		return _('写入规则文件失败');
	case 'FW4_RELOAD_FAILED_AFTER_RULE_WRITE':
		return _('写入新规则后重新加载 fw4 失败');
	case 'FW4_RELOAD_FAILED_AFTER_REMOVE_OLD_RULES':
		return _('删除旧规则后重新加载 fw4 失败');
	case 'FW4_RELOAD_FAILED_AFTER_DISABLE':
		return _('停用后重新加载 fw4 失败');
	case 'FW4_RELOAD_FAILED_AFTER_REMOVE_WHILE_DISABLED':
		return _('禁用状态下移除规则后重新加载 fw4 失败');
	case 'ANOTHER_APPLY_OR_RELOAD_IN_PROGRESS':
		return _('当前已有其他应用或重建任务正在进行');
	case 'UNKNOWN_APPLY_ERROR':
		return _('应用规则时发生未知错误');
	case 'UNKNOWN_DISABLE_ERROR':
		return _('停用规则时发生未知错误');
	case 'METHOD_NOT_FOUND':
		return _('RPC 方法不存在');
	default:
		return fallback || reasonCode;
	}
}

function formatRpcReply(resp, fallback) {
	var main = formatRpcCode(resp && resp.code, fallback);
	var reason = formatReasonCode(resp && resp.reason_code, '');

	if (reason)
		return _('%s：%s').format(main, reason);

	return main;
}

function setElementDisabled(el, disabled) {
	if (!el)
		return;

	if (disabled)
		el.setAttribute('disabled', 'disabled');
	else
		el.removeAttribute('disabled');
}

function renderIfaceList(items) {
	if (!Array.isArray(items) || items.length === 0)
		return E('div', {}, [ '-' ]);

	return E('ul', { 'style': 'margin:0;padding-left:1.2em' }, items.map(function(it) {
		var iface = it.interface || '-';
		var dev = it.device || '-';
		var prefix = it.prefix || '-';
		return E('li', {}, [ '%s (%s, %s)'.format(iface, dev, prefix) ]);
	}));
}

function renderStatusBox(status) {
	status = status || {};

	var statusReason = formatReasonCode(status.reason_code, status.reason);
	var rows = [
		E('tr', {}, [ E('td', { 'style': 'width:220px' }, _('启用状态')), E('td', {}, [ status.enabled ? _('已启用') : _('未启用') ]) ]),
		E('tr', {}, [ E('td', {}, _('已发现出口数')), E('td', {}, [ String(status.iface_count || 0) ]) ]),
		E('tr', {}, [ E('td', {}, _('规则文件存在')), E('td', {}, [ status.rule_file_exists ? _('是') : _('否') ]) ]),
		E('tr', {}, [ E('td', {}, _('nft 运行表存在')), E('td', {}, [ status.nft_table_present ? _('是') : _('否') ]) ]),
		E('tr', {}, [ E('td', {}, _('fw4 auto_includes')), E('td', {}, [ status.auto_includes ? _('是') : _('否') ]) ]),
		E('tr', {}, [ E('td', {}, _('当前环境可应用')), E('td', {}, [ status.ready ? _('是') : _('否') ]) ])
	];

	if (!status.ready && statusReason)
		rows.push(E('tr', {}, [ E('td', {}, _('不可应用原因')), E('td', {}, [ statusReason ]) ]));

	return E('div', {}, [
		E('table', { 'class': 'table' }, rows)
	]);
}

function renderCurrentRulesBox(current) {
	current = current || {};

	var rules = current.rules || '-';
	var source = formatRuleSource(current.source || 'none');
	var ifaces = current.interfaces || [];

	return E('div', {}, [
		E('table', { 'class': 'table' }, [
			E('tr', {}, [ E('td', { 'style': 'width:220px' }, _('规则来源')), E('td', {}, [ source ]) ]),
			E('tr', {}, [ E('td', {}, _('规则文件存在')), E('td', {}, [ current.rule_file_exists ? _('是') : _('否') ]) ]),
			E('tr', {}, [ E('td', {}, _('nft 运行表存在')), E('td', {}, [ current.nft_table_present ? _('是') : _('否') ]) ])
		]),
		E('div', { 'style': 'margin-top:1em' }, [
			E('label', { 'style': 'font-weight:bold;display:block;margin-bottom:.5em' }, [ _('当前已生效规则') ]),
			E('textarea', {
				'class': 'cbi-input-textarea',
				'readonly': 'readonly',
				'style': 'width:100%;min-height:240px'
			}, [ rules ])
		]),
		E('div', { 'style': 'margin-top:1em' }, [
			E('label', { 'style': 'font-weight:bold;display:block;margin-bottom:.5em' }, [ _('当前规则对应出口') ]),
			renderIfaceList(ifaces)
		])
	]);
}

function renderPreviewRulesBox(preview) {
	preview = preview || {};

	var rules = preview.rule_preview || '-';
	var ifaces = preview.interfaces || [];
	var previewReason = formatReasonCode(preview.reason_code, preview.reason);
	var rows = [
		E('tr', {}, [ E('td', { 'style': 'width:220px' }, _('当前环境可应用')), E('td', {}, [ preview.ready ? _('是') : _('否') ]) ]),
		E('tr', {}, [ E('td', {}, _('已发现出口数')), E('td', {}, [ String(preview.iface_count || 0) ]) ])
	];

	if (!preview.ready && previewReason)
		rows.push(E('tr', {}, [ E('td', {}, _('不可应用原因')), E('td', {}, [ previewReason ]) ]));

	return E('div', {}, [
		E('table', { 'class': 'table' }, rows),
		E('div', { 'style': 'margin-top:1em' }, [
			E('label', { 'style': 'font-weight:bold;display:block;margin-bottom:.5em' }, [ _('按当前环境生成的预览规则') ]),
			E('textarea', {
				'class': 'cbi-input-textarea',
				'readonly': 'readonly',
				'style': 'width:100%;min-height:240px'
			}, [ rules ])
		]),
		E('div', { 'style': 'margin-top:1em' }, [
			E('label', { 'style': 'font-weight:bold;display:block;margin-bottom:.5em' }, [ _('预览规则对应出口') ]),
			renderIfaceList(ifaces)
		])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callGetStatus(), {}),
			L.resolveDefault(callGetCurrentRules(), {})
		]);
	},

	render: function(data) {
		var self = this;
		var status = data[0] || {};
		var currentRules = data[1] || {};

		self._initialEnabled = !!status.enabled;
		self._latestPreview = {};
		self._latestCurrentRules = currentRules;
		self._busy = false;

		self.enabledInput = E('input', {
			'type': 'checkbox',
			'class': 'cbi-input-checkbox'
		});
		self.statusWrap = E('div');
		self.currentRulesWrap = E('div');
		self.previewRulesWrap = E('div');

		self.setBusy = function(busy) {
			self._busy = !!busy;
			setElementDisabled(self.enabledInput, self._busy);
			setElementDisabled(self.reloadBtn, self._busy);
			setElementDisabled(self.disableBtn, self._busy);
		};

		self.runBusy = function(fn) {
			if (self._busy)
				return Promise.resolve();

			self.setBusy(true);

			return Promise.resolve().then(function() {
				return fn();
			}).then(function(res) {
				self.setBusy(false);
				return res;
			}, function(err) {
				self.setBusy(false);
				return Promise.reject(err);
			});
		};

		self.enabledInput.checked = !!status.enabled;
		self.statusWrap.appendChild(renderStatusBox(status));
		self.currentRulesWrap.appendChild(renderCurrentRulesBox(self._latestCurrentRules));
		self.previewRulesWrap.appendChild(renderPreviewRulesBox(self._latestPreview));

		self.rerenderRules = function() {
			self.currentRulesWrap.innerHTML = '';
			self.previewRulesWrap.innerHTML = '';
			self.currentRulesWrap.appendChild(renderCurrentRulesBox(self._latestCurrentRules));
			self.previewRulesWrap.appendChild(renderPreviewRulesBox(self._latestPreview));
		};

		self.refreshStatus = function() {
			return callGetStatus().then(function(st) {
				self.statusWrap.innerHTML = '';
				self.statusWrap.appendChild(renderStatusBox(st || {}));

				if (st && typeof st.enabled !== 'undefined')
					self._initialEnabled = !!st.enabled;

				return st;
			}).catch(function(err) {
				self.statusWrap.innerHTML = '';
				self.statusWrap.appendChild(renderStatusBox({
					ok: false,
					code: 'STATUS_READ_FAILED',
					reason_code: '',
					reason: formatRpcError(_('读取状态'), err),
					enabled: !!self.enabledInput.checked,
					iface_count: 0,
					rule_file_exists: false,
					nft_table_present: false,
					auto_includes: false,
					ready: false
				}));
			});
		};

		self.refreshPreview = function() {
			return callTestRuntime(!!self.enabledInput.checked).then(function(pr) {
				self._latestPreview = pr || {};
				self.rerenderRules();
			}).catch(function(err) {
				self._latestPreview = {
					ok: false,
					code: 'RUNTIME_TEST_FAILED',
					reason_code: '',
					reason: formatRpcError(_('运行时预检'), err),
					enabled: !!self.enabledInput.checked,
					ready: false,
					rule_preview: '-',
					iface_count: 0,
					interfaces: []
				};
				self.rerenderRules();
			});
		};

		self.refreshCurrentRules = function() {
			return callGetCurrentRules().then(function(cr) {
				self._latestCurrentRules = cr || {};
				self.rerenderRules();
			}).catch(function(err) {
				self._latestCurrentRules = {
					ok: false,
					code: 'CURRENT_RULES_READ_FAILED',
					reason_code: '',
					source: 'none',
					rules: formatRpcError(_('读取当前规则'), err),
					nft_table_present: false,
					rule_file_exists: false,
					interfaces: []
				};
				self.rerenderRules();
			});
		};

		self.refreshStatusPreview = function() {
			return Promise.all([
				self.refreshStatus(),
				self.refreshPreview()
			]);
		};

		self.refreshAll = function() {
			return Promise.all([
				self.refreshStatus(),
				self.refreshPreview(),
				self.refreshCurrentRules()
			]);
		};

		self.enabledInput.addEventListener('change', function() {
			if (!self._busy)
				self.refreshPreview();
		});

		self.refreshPreview();

		var disableRules = ui.createHandlerFn(this, function() {
			return self.runBusy(function() {
				return callDisable().then(function(r) {
					if (!notifyRpcReply(r, _('已停用并移除规则'), _('停用并移除规则失败')))
						return;

					self.enabledInput.checked = false;
					self._initialEnabled = false;

					return self.refreshAll();
				}).catch(function(err) {
					notify(formatRpcError(_('停用并移除规则'), err), 'warning');
				});
			});
		});

		var reloadRuntime = ui.createHandlerFn(this, function() {
			return self.runBusy(function() {
				return callReloadRuntime().then(function(r) {
					notifyRpcReply(r, _('已按当前配置重新检测并重建规则'), _('按当前配置重新检测并重建失败'));
					return self.refreshAll();
				}).catch(function(err) {
					notify(formatRpcError(_('按当前配置重新检测并重建'), err), 'warning');
				});
			});
		});

		self.reloadBtn = E('button', {
			'class': 'btn cbi-button',
			'click': reloadRuntime
		}, [ _('按当前配置重建') ]);

		self.disableBtn = E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': disableRules
		}, [ _('停用并移除规则') ]);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('IPv6 Prefix SNAT') ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-node' }, [
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('启用') ]),
						E('div', { 'class': 'cbi-value-field' }, [ self.enabledInput ])
					]),
					E('div', { 'class': 'cbi-value' }, [
						E('label', { 'class': 'cbi-value-title' }, [ _('当前运行状态') ]),
						E('div', { 'class': 'cbi-value-field' }, [ self.statusWrap ])
					]),
					E('div', {
						'style': 'display:flex;justify-content:flex-end;gap:.5em;margin-top:1em;padding:0;background:none;box-shadow:none;border:none'
					}, [
						self.reloadBtn,
						self.disableBtn
					])
				])
			]),

			E('div', { 'class': 'cbi-section', 'style': 'margin-top:1.5em' }, [
				E('h3', {}, [ _('运行时预览规则') ]),
				E('div', { 'class': 'cbi-section-node' }, [ self.previewRulesWrap ])
			]),

			E('div', { 'class': 'cbi-section', 'style': 'margin-top:1.5em' }, [
				E('h3', {}, [ _('当前已生效规则') ]),
				E('div', { 'class': 'cbi-section-node' }, [ self.currentRulesWrap ])
			])
		]);
	},

	saveConfig: function() {
		var self = this;
		var enabled = !!(self.enabledInput && self.enabledInput.checked);

		return callSetConfig(enabled).then(function(r) {
			if (!notifyRpcReply(r, _('配置已保存'), _('保存配置失败')))
				return Promise.reject(new Error(formatRpcReply(r, 'save failed')));

			self._initialEnabled = enabled;
			return r;
		});
	},

	handleSave: function() {
		var self = this;

		return self.runBusy(function() {
			return self.saveConfig().then(function() {
				return self.refreshStatusPreview();
			});
		});
	},

	handleSaveApply: function() {
		var self = this;

		return self.runBusy(function() {
			return self.saveConfig().then(function() {
				return callApply().then(function(r) {
					if (!notifyRpcReply(r, _('规则已应用'), _('保存成功，但应用规则失败')))
						return Promise.reject(new Error(formatRpcReply(r, 'apply failed')));

					return self.refreshAll();
				}).catch(function(err) {
					return self.refreshAll().then(function() {
						return Promise.reject(err);
					});
				});
			});
		});
	},

	handleReset: function() {
		var self = this;

		return self.runBusy(function() {
			if (self.enabledInput)
				self.enabledInput.checked = !!self._initialEnabled;

			return self.refreshAll();
		});
	}
});
