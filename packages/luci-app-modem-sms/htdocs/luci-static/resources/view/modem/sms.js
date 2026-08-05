'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require poll';

const callCapabilities = rpc.declare({
	object: 'modem.sms',
	method: 'capabilities'
});

const callList = rpc.declare({
	object: 'modem.sms',
	method: 'list',
	params: [ 'box', 'storage', 'limit', 'refresh' ]
});

const callGet = rpc.declare({
	object: 'modem.sms',
	method: 'get',
	params: [ 'id' ]
});

const callAnalyse = rpc.declare({
	object: 'modem.sms',
	method: 'analyse',
	params: [ 'text' ]
});

const callSend = rpc.declare({
	object: 'modem.sms',
	method: 'send',
	params: [ 'to', 'text', 'request_id' ]
});

const callStatus = rpc.declare({
	object: 'modem.sms',
	method: 'status',
	params: [ 'request_id' ]
});

const ACTIVE_REQUEST_KEY = 'modem-sms.active-request-id';
const ACTIVE_REQUEST_PREFIX = 'modem-sms.active-request.';

function storedRequestIds() {
	try {
		const values = [];
		for (let i = 0; i < window.localStorage.length; i++) {
			const key = window.localStorage.key(i);
			if (key && key.startsWith(ACTIVE_REQUEST_PREFIX))
				values.push(key.slice(ACTIVE_REQUEST_PREFIX.length));
		}

		/* One-time migration from the earlier shared-array key. Per-request
		 * keys avoid cross-tab read-modify-write races. */
		const raw = window.localStorage.getItem(ACTIVE_REQUEST_KEY) || '';
		let legacy;
		try { legacy = JSON.parse(raw); }
		catch (error) { legacy = raw ? [ raw ] : []; }
		if (!Array.isArray(legacy))
			legacy = [];
		legacy.forEach(value => values.push(value));

		const valid = Array.from(new Set(values.filter(value =>
			typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/.test(value)))).slice(0, 500);
		legacy.forEach(value => {
			if (valid.includes(value))
				window.localStorage.setItem(ACTIVE_REQUEST_PREFIX + value, '1');
		});
		if (raw)
			window.localStorage.removeItem(ACTIVE_REQUEST_KEY);
		return valid;
	}
	catch (error) {
		return [];
	}
}

function storeRequestId(value) {
	try {
		window.localStorage.setItem(ACTIVE_REQUEST_PREFIX + value, '1');
	}
	catch (error) { /* The backend still provides durable idempotency. */ }
}

function clearStoredRequestId(value) {
	try {
		if (value)
			window.localStorage.removeItem(ACTIVE_REQUEST_PREFIX + value);
		const remaining = storedRequestIds().filter(item => value && item !== value);
		return remaining[0] || null;
	}
	catch (error) { return null; }
}

function requestId() {
	if (window.crypto && window.crypto.randomUUID)
		return window.crypto.randomUUID();

	if (window.crypto && window.crypto.getRandomValues) {
		const bytes = new Uint8Array(16);
		window.crypto.getRandomValues(bytes);
		return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
	}

	return 'sms-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
}

function formatEpoch(value) {
	if (!value)
		return _('Never');
	return new Date(value * 1000).toLocaleString();
}

function stateLabel(state) {
	return ({
		received: _('Received'),
		stored: _('Stored'),
		delivered: _('Delivered'),
		'delivery-failed': _('Delivery failed'),
		queued: _('Queued'),
		sending: _('Sending'),
		pending: _('Confirmation pending'),
		sent: _('Submitted to modem'),
		partial: _('Partially submitted'),
		failed: _('Failed'),
		unknown: _('Unknown')
	})[state] || state || _('Unknown');
}

function messageStatusLabel(message) {
	if (message && message.direction === 'outbound' && message.storage_status === 'STO SENT')
		return _('Stored as sent');
	if (message && message.direction === 'outbound' && message.storage_status === 'STO UNSENT')
		return _('Stored as unsent');
	if (message && message.direction === 'inbound' && message.storage_status === 'REC UNREAD')
		return _('Received unread');
	if (message && message.direction === 'inbound' && message.storage_status === 'REC READ')
		return _('Received read');
	return stateLabel(message && message.status);
}

function effectiveSendState(status) {
	const state = status && status.state || 'pending';
	const submitted = +(status && status.parts_submitted || 0);
	const segments = +(status && status.segments || 0);

	if (segments > 0 && submitted < segments && ['sent', 'delivered'].includes(state))
		return submitted > 0 ? 'partial' : 'unknown';

	if (submitted > 0 && segments > submitted && ['failed', 'unknown'].includes(state))
		return 'partial';

	return state;
}

function isSuccessfulSendState(state) {
	return state === 'sent' || state === 'delivered';
}

function isTerminalSendState(state) {
	return ['sent', 'partial', 'failed', 'unknown', 'delivered', 'delivery-failed'].includes(state);
}

function sendStateDetail(status) {
	const state = effectiveSendState(status);
	const submitted = +(status && status.parts_submitted || 0);
	const segments = +(status && status.segments || 0);

	if (state === 'sent')
		return _('Every segment was accepted by the modem. This is not a handset delivery receipt.');
	if (state === 'delivered')
		return _('A delivery report confirms handset delivery.');
	if (state === 'delivery-failed')
		return _('A delivery report says that handset delivery failed.');
	if (state === 'partial')
		return _('Only %d of %d segments are known to have been submitted. Do not resend until you have checked for duplicates.')
			.format(submitted, segments);
	if (state === 'unknown')
		return _('The submission outcome is unknown. The same request ID is retained and no automatic resend will occur.');
	if (state === 'failed')
		return _('The modem rejected the submission. The message draft has been kept.');
	if (state === 'queued')
		return _('The message is queued for submission to the modem.');
	if (state === 'sending')
		return _('The modem is submitting the message segments.');
	return _('The submit response was not received. Checking the same request ID without resending.');
}

function storageText(storage) {
	const parts = [];
	Object.keys(storage || {}).forEach(name => {
		const item = storage[name] || {};
		const percent = item.used != null && item.total > 0
			? ' (%d%%)'.format(Math.round(item.used * 100 / item.total)) : '';
		parts.push('%s: %s/%s%s'.format(name, item.used == null ? '—' : item.used,
			item.total == null ? '—' : item.total, percent));
	});
	return parts.length ? parts.join(' · ') : _('Not loaded');
}

function storageWarning(storage) {
	let maximum = 0;
	Object.values(storage || {}).forEach(item => {
		if (item && item.used != null && item.total > 0)
			maximum = Math.max(maximum, item.used * 100 / item.total);
	});
	if (maximum >= 90)
		return _('SMS storage is at least 90% full. Device deletion is temporarily disabled until the safe archive workflow is available.');
	if (maximum >= 80)
		return _('SMS storage is at least 80% full. Device deletion is temporarily disabled until the safe archive workflow is available.');
	return '';
}

function storageErrorText(errors) {
	return (errors || []).map(item => {
		if (!item)
			return '';
		const name = item.storage ? `${item.storage}: ` : '';
		const detail = item.detail ? ` (${item.detail})` : '';
		return `${name}${item.error_code || _('Unknown error')}${detail}`;
	}).filter(Boolean).join(', ');
}

return view.extend({
	capabilities: null,
	data: null,
	box: 'inbox',
	sendAttempt: null,
	recoveredRequestId: null,
	recoveredRequestIds: [],
	recoveryReloadPending: false,

	load() {
		this.recoveredRequestIds = storedRequestIds();
		this.recoveredRequestId = this.recoveredRequestIds[0] || null;
		return Promise.all([
			callCapabilities().catch(function(err) {
				console.error('modem-sms: capabilities RPC failed', err);
				return { ok: false, error_code: 'SERVICE_UNAVAILABLE' };
			}),
			callList('inbox', 'ALL', 100, false).catch(function(err) {
				console.error('modem-sms: list RPC failed', err);
				return { ok: false, messages: [] };
			}),
			Promise.all(this.recoveredRequestIds.map(function(id) {
				return callStatus(id).catch(function(err) {
					console.error('modem-sms: status RPC failed for', id, err);
					return { ok: false, error_code: 'SERVICE_UNAVAILABLE' };
				});
			}))
		]);
	},

	showError(result) {
		ui.addNotification(null, E('p', {}, [
			_('Operation failed: %s').format(result && result.error_code || _('Unknown error'))
		]));
	},

	refresh(force) {
		const button = document.querySelector('#sms-refresh');
		if (button)
			button.disabled = true;

		return L.resolveDefault(callList(this.box, 'ALL', 100, !!force), { ok: false, messages: [] })
			.then(result => {
				if (!result.ok) {
					this.showError(result);
					return false;
				}
				else {
					this.data = result;
					this.renderMessages();
					return true;
				}
			})
			.finally(() => {
				if (button)
					button.disabled = false;
			});
	},

	renderMessages() {
		const host = document.querySelector('#sms-message-list');
		if (!host)
			return;

		const messages = this.data && this.data.messages || [];
		const rows = messages.map(message => E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td' }, [ message.timestamp || '—' ]),
			E('div', { 'class': 'td' }, [ message.number || '—' ]),
			E('div', { 'class': 'td' }, [ message.preview || '' ]),
			E('div', { 'class': 'td' }, [
				message.complete === false
					? _('%d/%d parts').format(message.parts_received, message.segments)
					: '%s · %s'.format(message.encoding || '—', messageStatusLabel(message))
			]),
			E('div', { 'class': 'td' }, [ message.storage || '—' ]),
			E('div', { 'class': 'td right' }, [
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'showMessage', message.id)
				}, [ _('Details') ])
			])
		]));

		if (!rows.length)
			rows.push(E('div', { 'class': 'tr' }, [
				E('div', { 'class': 'td center', 'style': 'flex:1' }, [
					this.data && this.data.loading ? _('Loading messages from the modem…') : _('No messages')
				])
			]));

		dom.content(host, [
			E('div', { 'class': 'table', 'id': 'sms-table' }, [
				E('div', { 'class': 'tr table-titles' }, [
					E('div', { 'class': 'th' }, [ _('Time') ]),
					E('div', { 'class': 'th' }, [ _('Number') ]),
					E('div', { 'class': 'th' }, [ _('Message') ]),
					E('div', { 'class': 'th' }, [ _('Encoding / status') ]),
					E('div', { 'class': 'th' }, [ _('Storage') ]),
					E('div', { 'class': 'th right' }, [ _('Actions') ])
				]),
				...rows
			])
		]);

		const meta = document.querySelector('#sms-cache-meta');
		if (meta)
			meta.textContent = '%s · %s'.format(
				_('Updated %s').format(formatEpoch(this.data.updated_at)),
				storageText(this.data.storage));

		const warning = document.querySelector('#sms-storage-warning');
		if (warning) {
			const storageErrors = storageErrorText(this.data && this.data.errors);
			warning.textContent = this.data && this.data.loading
				? _('The modem is being read. This may take up to four minutes on a cold start.')
				: !this.data.ok
				? _('SMS messages could not be loaded: %s').format(this.data.error_code || _('Unknown error'))
				: this.data.stale
					? _('Some modem storage could not be read. The displayed message list may be incomplete. %s').format(storageErrors)
					: storageWarning(this.data.storage);
			warning.style.display = warning.textContent ? '' : 'none';
		}
	},

	showMessage(id) {
		return L.resolveDefault(callGet(id), { ok: false, error_code: 'SERVICE_UNAVAILABLE' }).then(result => {
			if (!result.ok) {
				this.showError(result);
				return;
			}

			const message = result.message;
			ui.showModal(_('SMS details'), [
				E('dl', {}, [
					E('dt', {}, [ _('Number') ]), E('dd', {}, [ message.number || '—' ]),
					E('dt', {}, [ _('Time') ]), E('dd', {}, [ message.timestamp || '—' ]),
					E('dt', {}, [ _('Status') ]), E('dd', {}, [ messageStatusLabel(message) ]),
					E('dt', {}, [ _('Encoding') ]), E('dd', {}, [ message.encoding || '—' ]),
					E('dt', {}, [ _('Storage') ]), E('dd', {}, [ message.storage || '—' ])
				]),
				E('pre', { 'style': 'white-space:pre-wrap;overflow-wrap:anywhere' }, [ message.text || '' ]),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Close') ])
				])
			]);
		});
	},

	updateAnalysis() {
		const text = document.querySelector('#sms-text').value;
		const host = document.querySelector('#sms-analysis');
		if (!text) {
			host.textContent = _('Enter a message to see encoding and segment count.');
			return Promise.resolve();
		}
		return L.resolveDefault(callAnalyse(text), { ok: false, error_code: 'SERVICE_UNAVAILABLE' }).then(result => {
			host.textContent = result.ok
				? _('%s · %d unit(s) · %d segment(s)').format(result.encoding, result.units, result.segments)
				: _('Unable to analyse message');
		});
	},

	sendMessage() {
		if (this.recoveryReloadPending)
			return Promise.resolve();
		const to = document.querySelector('#sms-to').value.trim();
		const text = document.querySelector('#sms-text').value;
		if (!/^\+?[0-9]{3,20}$/.test(to) || !text) {
			this.showError({ error_code: _('Enter a valid number and a non-empty message') });
			return;
		}

		const previous = this.sendAttempt;
		if (previous && previous.started) {
			const previousState = effectiveSendState(previous.lastStatus);
			if (!previous.success && previousState !== 'failed' && previousState !== 'delivery-failed') {
				this.showSendStatus(previous);
				if (!previous.terminal)
					this.startSendPolling(previous);
				return Promise.resolve();
			}
		}

		return L.resolveDefault(callAnalyse(text), { ok: false, error_code: 'SERVICE_UNAVAILABLE' }).then(analysis => {
			if (!analysis.ok) {
				this.showError(analysis);
				return;
			}

			const attempt = {
				requestId: requestId(),
				to: to,
				text: text,
				started: false,
				terminal: false,
				success: false,
				pollBusy: false,
				pollTimer: null,
				lastStatus: {
					ok: true,
					state: 'pending',
					encoding: analysis.encoding,
					segments: analysis.segments,
					parts_submitted: 0
				}
			};
			this.sendAttempt = attempt;
			ui.showModal(_('Confirm SMS'), [
				E('p', {}, [ _('Send to %s?').format(to) ]),
				E('p', {}, [ _('%s · %d segment(s). Your carrier may charge per segment.').format(
					analysis.encoding, analysis.segments) ]),
				E('pre', { 'style': 'white-space:pre-wrap;max-height:12em;overflow:auto' }, [ text ]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'id': 'sms-confirm-cancel',
						'class': 'btn',
						'click': ui.createHandlerFn(this, function() {
							if (!attempt.started && this.sendAttempt === attempt)
								this.sendAttempt = null;
							ui.hideModal();
						})
					}, [ _('Cancel') ]),
					' ',
					E('button', {
						'id': 'sms-confirm-send',
						'class': 'btn cbi-button-positive important',
						'click': ui.createHandlerFn(this, function() {
							return this.submitConfirmed(attempt, document.querySelector('#sms-confirm-send'));
						})
					}, [ _('Send') ])
				])
			]);
		});
	},

	showSendStatus(attempt) {
		attempt.statusOpen = true;
		ui.showModal(_('SMS submission status'), [
			E('dl', {}, [
				E('dt', {}, [ _('Status') ]),
				E('dd', { 'id': 'sms-send-state' }),
				E('dt', {}, [ _('Progress') ]),
				E('dd', { 'id': 'sms-send-progress' }),
				E('dt', {}, [ _('Request ID') ]),
				E('dd', {}, [ E('code', {}, [ attempt.requestId ]) ]),
				E('dt', { 'id': 'sms-send-error-label', 'style': 'display:none' }, [ _('Error code') ]),
				E('dd', { 'id': 'sms-send-error', 'style': 'display:none' })
			]),
			E('p', { 'id': 'sms-send-detail' }),
			E('p', {
				'id': 'sms-send-poll-warning',
				'class': 'alert-message warning',
				'style': 'display:none'
			}),
			E('div', { 'class': 'right' }, [
				attempt.terminal && !attempt.success && ['unknown', 'partial'].includes(effectiveSendState(attempt.lastStatus))
					? E('button', {
						'class': 'btn cbi-button-negative',
						'click': ui.createHandlerFn(this, function() {
							this.recoveredRequestId = clearStoredRequestId(attempt.requestId);
							if (this.sendAttempt === attempt)
								this.sendAttempt = null;
							ui.hideModal();
							ui.addNotification(null, E('p', {}, [
								_('The previous request ID was released. Sending again may duplicate a message whose outcome was unknown.')
							]));
							window.setTimeout(() => window.location.reload(), 0);
						})
					}, [ _('Release request ID') ]) : '',
				' ',
				E('button', {
					'id': 'sms-check-status',
					'class': 'btn cbi-button-action',
					'disabled': attempt.terminal ? '' : null,
					'click': ui.createHandlerFn(this, function() {
						return this.checkSendStatus(attempt, document.querySelector('#sms-check-status'));
					})
				}, [ _('Check status') ]),
				' ',
				E('button', {
					'class': 'btn',
					'click': ui.createHandlerFn(this, function() {
						attempt.statusOpen = false;
						this.stopSendPolling(attempt);
						ui.hideModal();
					})
				}, [ _('Close') ])
			])
		]);
		this.updateSendStatus(attempt);
	},

	updateSendStatus(attempt) {
		const status = attempt.lastStatus || { state: 'pending', parts_submitted: 0, segments: 0 };
		const state = effectiveSendState(status);
		const stateNode = document.querySelector('#sms-send-state');
		const progressNode = document.querySelector('#sms-send-progress');
		const detailNode = document.querySelector('#sms-send-detail');
		const warningNode = document.querySelector('#sms-send-poll-warning');
		const checkButton = document.querySelector('#sms-check-status');
		const errorLabel = document.querySelector('#sms-send-error-label');
		const errorNode = document.querySelector('#sms-send-error');
		const errorCode = status.error_code || attempt.submitError;

		if (stateNode)
			stateNode.textContent = stateLabel(state);
		if (progressNode)
			progressNode.textContent = _('%d/%d segments submitted').format(
				status.parts_submitted || 0, status.segments || 0);
		if (detailNode)
			detailNode.textContent = sendStateDetail(status);
		if (errorLabel)
			errorLabel.style.display = errorCode ? '' : 'none';
		if (errorNode) {
			errorNode.textContent = errorCode || '';
			errorNode.style.display = errorCode ? '' : 'none';
		}
		if (warningNode) {
			warningNode.textContent = attempt.lastPollError
				? _('Status check failed temporarily (%s). The draft was kept and no resend occurred.')
					.format(attempt.lastPollError)
				: '';
			warningNode.style.display = warningNode.textContent ? '' : 'none';
		}
		if (checkButton)
			checkButton.disabled = attempt.pollBusy || attempt.terminal;
	},

	stopSendPolling(attempt) {
		attempt.pollEnabled = false;
		if (attempt.pollTimer != null) {
			window.clearTimeout(attempt.pollTimer);
			attempt.pollTimer = null;
		}
	},

	finishSendAttempt(attempt) {
		const state = effectiveSendState(attempt.lastStatus);
		attempt.terminal = true;
		attempt.success = isSuccessfulSendState(state);
		this.stopSendPolling(attempt);
		this.updateSendStatus(attempt);
		if (attempt.success || state === 'failed' || state === 'delivery-failed') {
			const nextRequestId = clearStoredRequestId(attempt.requestId);
			if (this.recoveredRequestId === attempt.requestId) {
				this.recoveredRequestId = null;
				if (nextRequestId) {
					this.recoveryReloadPending = true;
					window.setTimeout(() => window.location.reload(), 0);
				}
			}
		}

		if (!attempt.success)
			return;

		const toNode = document.querySelector('#sms-to');
		const textNode = document.querySelector('#sms-text');
		if (toNode && textNode && toNode.value.trim() === attempt.to && textNode.value === attempt.text) {
			textNode.value = '';
			this.updateAnalysis();
		}
		this.refresh(true);
	},

	checkSendStatus(attempt, button) {
		if (attempt.pollBusy || attempt.terminal)
			return Promise.resolve();

		attempt.pollBusy = true;
		if (button)
			button.disabled = true;
		this.updateSendStatus(attempt);

		return L.resolveDefault(callStatus(attempt.requestId),
			{ ok: false, error_code: 'SERVICE_UNAVAILABLE' }).then(status => {
			attempt.pollBusy = false;
			if (!status.ok) {
				attempt.lastPollError = status.error_code || 'SERVICE_UNAVAILABLE';
				this.updateSendStatus(attempt);
				return;
			}

			attempt.lastPollError = null;
			attempt.submitUncertain = false;
			attempt.lastStatus = status;
			const state = effectiveSendState(status);
			if (isTerminalSendState(state))
				this.finishSendAttempt(attempt);
			else
				this.updateSendStatus(attempt);
		}).finally(() => {
			attempt.pollBusy = false;
			this.updateSendStatus(attempt);
		});
	},

	startSendPolling(attempt) {
		this.stopSendPolling(attempt);
		if (attempt.terminal)
			return;
		attempt.pollEnabled = true;

		const pollStatus = () => {
			if (!attempt.pollEnabled)
				return;
			this.checkSendStatus(attempt).finally(() => {
				if (attempt.pollEnabled && !attempt.terminal)
					attempt.pollTimer = window.setTimeout(pollStatus, 1500);
			});
		};
		attempt.pollTimer = window.setTimeout(pollStatus, 500);
	},

	submitConfirmed(attempt, button) {
		if (attempt.started)
			return Promise.resolve();

		attempt.started = true;
		storeRequestId(attempt.requestId);
		this.recoveredRequestId = attempt.requestId;
		if (button)
			button.disabled = true;
		const cancelButton = document.querySelector('#sms-confirm-cancel');
		if (cancelButton)
			cancelButton.disabled = true;

		this.showSendStatus(attempt);
		return L.resolveDefault(callSend(attempt.to, attempt.text, attempt.requestId), {
			ok: false,
			transport_pending: true,
			error_code: 'SERVICE_UNAVAILABLE'
		}).then(result => {
			if (!result.ok && !result.transport_pending) {
				if (result.error_code === 'REQUEST_ID_CONFLICT') {
					attempt.lastStatus = {
						ok: true,
						state: 'unknown',
						encoding: attempt.lastStatus.encoding,
						segments: attempt.lastStatus.segments,
						parts_submitted: 0,
						error_code: result.error_code
					};
					attempt.submitError = result.error_code;
					attempt.terminal = true;
					this.updateSendStatus(attempt);
					this.recoveryReloadPending = true;
					window.setTimeout(() => window.location.reload(), 0);
					return;
				}
				attempt.lastStatus = {
					ok: true,
					state: 'failed',
					encoding: attempt.lastStatus.encoding,
					segments: attempt.lastStatus.segments,
					parts_submitted: 0,
					error_code: result.error_code
				};
				attempt.submitError = result.error_code;
				attempt.lastPollError = null;
				this.finishSendAttempt(attempt);
				return;
			}

			if (result.ok) {
				attempt.lastStatus = result;
				attempt.submitError = null;
				attempt.lastPollError = null;
				const state = effectiveSendState(result);
				if (isTerminalSendState(state)) {
					this.finishSendAttempt(attempt);
					return;
				}
			}
			else {
				attempt.submitUncertain = true;
			}

			this.updateSendStatus(attempt);
			if (attempt.statusOpen)
				this.startSendPolling(attempt);
		});
	},

	render(data) {
		this.capabilities = (data && data[0]) || {};
		this.data = (data && data[1]) || { ok: false, messages: [] };
		const recoveredStatuses = (data && data[2]) || [];
		this.sendAttempt = null;
		for (let i = 0; i < this.recoveredRequestIds.length; i++) {
			const id = this.recoveredRequestIds[i];
			const recovered = recoveredStatuses[i];
			if (!recovered || !recovered.ok) {
				if (!this.sendAttempt) {
					this.recoveredRequestId = id;
					this.sendAttempt = {
						requestId: id,
						to: null,
						text: null,
						started: true,
						terminal: true,
						success: false,
						pollBusy: false,
						pollTimer: null,
						lastStatus: {
							ok: true,
							state: 'unknown',
							parts_submitted: 0,
							segments: 0,
							error_code: recovered && recovered.error_code || 'RECOVERY_STATUS_UNAVAILABLE'
						}
					};
				}
				continue;
			}
			const recoveredState = effectiveSendState(recovered);
			if (['sent', 'delivered', 'failed', 'delivery-failed'].includes(recoveredState)) {
				clearStoredRequestId(id);
				continue;
			}
			if (!this.sendAttempt) {
				this.recoveredRequestId = id;
				this.sendAttempt = {
					requestId: id,
					to: null,
					text: null,
					started: true,
					terminal: isTerminalSendState(recoveredState),
					success: false,
					pollBusy: false,
					pollTimer: null,
					lastStatus: recovered
				};
			}
		}
		this.recoveredRequestIds = storedRequestIds();
		if (!this.sendAttempt)
			this.recoveredRequestId = this.recoveredRequestIds[0] || null;
		const unavailable = !this.capabilities.ok || !this.capabilities.backend_available;
		const unavailableDetail = !this.capabilities.ok
			? (this.capabilities.error_code || 'SERVICE_UNAVAILABLE')
			: (!this.capabilities.backend_available ? 'BACKEND_UNAVAILABLE' : null);

		const node = E('div', {}, [
			E('h2', {}, [ _('SMS Center') ]),
			E('p', {}, [ _('Read and send standard SMS messages through the modem. Messages and identifiers are masked by default.') ]),
			unavailable ? E('div', { 'class': 'alert-message warning' }, [
				_('SMS backend is unavailable. Mobile data service is not affected.'),
				unavailableDetail ? E('br') : '',
				unavailableDetail ? E('code', {}, [ unavailableDetail ]) : ''
			]) : '',
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Messages') ]),
				this.capabilities.read_may_mark_read ? E('div', { 'class': 'alert-message warning' }, [
					_('Refreshing messages may change REC UNREAD to REC READ in modem storage.')
				]) : '',
				this.capabilities.features && this.capabilities.features.delete === false
					? E('div', { 'class': 'alert-message warning' }, [
						_('Device message deletion is temporarily disabled until the safe local archive workflow is available.')
					]) : '',
				E('div', { 'style': 'display:flex;gap:.5rem;align-items:center;flex-wrap:wrap' }, [
					E('button', { 'class': 'btn', 'click': ui.createHandlerFn(this, function() {
						this.box = 'inbox'; return this.refresh(false);
					}) }, [ _('Inbox') ]),
					E('button', { 'class': 'btn', 'click': ui.createHandlerFn(this, function() {
						this.box = 'outbox'; return this.refresh(false);
					}) }, [ _('Outbox') ]),
					E('button', { 'id': 'sms-refresh', 'class': 'btn cbi-button-action',
						'click': ui.createHandlerFn(this, 'refresh', true) }, [ _('Refresh modem') ]),
					E('span', { 'id': 'sms-cache-meta', 'class': 'fade' })
				]),
				E('div', { 'id': 'sms-storage-warning', 'class': 'alert-message warning', 'style': 'display:none' }),
				E('div', { 'id': 'sms-message-list', 'style': 'margin-top:1rem' })
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Compose') ]),
				this.recoveredRequestId ? E('div', { 'class': 'alert-message warning' }, [
					_('A previous request ID is still protected against duplicate submission: %s').format(this.recoveredRequestId),
					' ',
					this.sendAttempt ? E('button', {
						'class': 'btn cbi-button-action',
						'click': ui.createHandlerFn(this, function() {
							this.showSendStatus(this.sendAttempt);
							if (!this.sendAttempt.terminal)
								this.startSendPolling(this.sendAttempt);
						})
					}, [ _('View status') ]) : ''
				]) : '',
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'sms-to' }, [ _('Recipient') ]),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', { 'id': 'sms-to', 'type': 'tel', 'maxlength': 21, 'placeholder': '+8613800000000' })
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'sms-text' }, [ _('Message') ]),
					E('div', { 'class': 'cbi-value-field' }, [
						E('textarea', { 'id': 'sms-text', 'rows': 5, 'maxlength': 2048,
							'input': L.bind(this.updateAnalysis, this) }),
						E('div', { 'id': 'sms-analysis', 'class': 'cbi-value-description' }, [
							_('Enter a message to see encoding and segment count.')
						])
					])
				]),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', { 'class': 'btn cbi-button-positive important', 'disabled': unavailable ? '' : null,
						'click': ui.createHandlerFn(this, 'sendMessage') }, [ _('Review and send') ])
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('Diagnostics') ]),
				E('dl', {}, [
					E('dt', {}, [ _('Backend') ]), E('dd', {}, [ this.capabilities.backend_id || '—' ]),
					E('dt', {}, [ _('Transport') ]), E('dd', {}, [ this.capabilities.transport || '—' ]),
					E('dt', {}, [ _('Encodings') ]), E('dd', {}, [ (this.capabilities.encodings || []).join(', ') || '—' ]),
					E('dt', {}, [ _('Storage') ]), E('dd', {}, [ storageText(this.data.storage) ])
				])
			])
		]);

		window.setTimeout(() => this.renderMessages(), 0);
		if (this.data && this.data.loading)
			window.setTimeout(() => this.refresh(false), 1000);
		if (!unavailable)
			poll.add(() => this.refresh(false), 30);
		return node;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
