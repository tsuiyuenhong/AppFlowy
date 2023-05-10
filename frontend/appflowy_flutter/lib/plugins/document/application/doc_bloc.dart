import 'package:appflowy/plugins/document/application/document_data_pb_extension.dart';
import 'package:appflowy/plugins/trash/application/trash_service.dart';
import 'package:appflowy/user/application/user_service.dart';
import 'package:appflowy/util/json_print.dart';
import 'package:appflowy/workspace/application/view/view_listener.dart';
import 'package:appflowy/workspace/application/doc/doc_listener.dart';
import 'package:appflowy/plugins/document/application/doc_service.dart';
import 'package:appflowy_backend/log.dart';
import 'package:appflowy_backend/protobuf/flowy-document2/protobuf.dart';
import 'package:appflowy_backend/protobuf/flowy-user/user_profile.pbserver.dart';
import 'package:appflowy_editor/appflowy_editor.dart'
    show
        EditorState,
        Transaction,
        Operation,
        InsertOperation,
        UpdateOperation,
        DeleteOperation,
        PathExtensions,
        Node;
import 'package:appflowy_backend/protobuf/flowy-error/errors.pb.dart';
import 'package:appflowy_backend/protobuf/flowy-folder2/view.pb.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:dartz/dartz.dart';
import 'dart:async';
part 'doc_bloc.freezed.dart';

class DocumentBloc extends Bloc<DocumentEvent, DocumentState> {
  DocumentBloc({
    required this.view,
  })  : _documentListener = DocumentListener(id: view.id),
        _viewListener = ViewListener(view: view),
        _documentService = DocumentService(),
        _trashService = TrashService(),
        super(DocumentState.initial()) {
    _transactionAdapter = TransactionAdapter(
      documentId: view.id,
      documentService: _documentService,
    );
    on<DocumentEvent>(_onDocumentEvent);
  }

  final ViewPB view;

  final DocumentListener _documentListener;
  final ViewListener _viewListener;

  final DocumentService _documentService;
  final TrashService _trashService;

  late final TransactionAdapter _transactionAdapter;

  EditorState? editorState;
  StreamSubscription? _subscription;

  @override
  Future<void> close() async {
    await _viewListener.stop();
    await _subscription?.cancel();
    await _documentService.closeDocumentV2(view: view);
    return super.close();
  }

  Future<void> _onDocumentEvent(
    DocumentEvent event,
    Emitter<DocumentState> emit,
  ) async {
    await event.map(
      initial: (Initial value) async {
        final state = await _fetchDocumentState();
        await _subscribe(state);
        emit(state);
      },
      deleted: (Deleted value) async {
        emit(state.copyWith(isDeleted: true));
      },
      restore: (Restore value) async {
        emit(state.copyWith(isDeleted: false));
      },
      deletePermanently: (DeletePermanently value) async {
        final result = await _trashService.deleteViews([view.id]);
        // TODO: swap the Either. Left should be the erorr.
        emit(state.copyWith(forceClose: result.isLeft()));
      },
      restorePage: (RestorePage value) async {
        final result = await _trashService.putback(view.id);
        // TODO: swap the Either. Left should be the erorr.
        emit(state.copyWith(isDeleted: result.isLeft()));
      },
    );
  }

  Future<void> _subscribe(DocumentState state) async {
    _onViewChanged();
    _onDocumentChanged();

    // create the editor state
    await state.loadingState.whenOrNull(
      finish: (data) async => data.map((r) {
        _initAppFlowyEditorState(r);
      }),
    );
  }

  /// subscribe to the view(document page) change
  void _onViewChanged() {
    _viewListener.start(
      onViewDeleted: (r) => r.map((r) => add(const DocumentEvent.deleted())),
      onViewRestored: (r) => r.map((r) => add(const DocumentEvent.restore())),
    );
  }

  /// subscribe to the document content change
  void _onDocumentChanged() {
    _documentListener.start(
      didReceiveUpdate: (docEvent) {
        // todo: integrate the document change to the editor
        // prettyPrintJson(docEvent.toProto3Json());
      },
    );
  }

  /// Fetch document
  Future<DocumentState> _fetchDocumentState() async {
    final result = await UserBackendService.getCurrentUserProfile().then(
      (value) async => value.andThen(
        // open the document
        await _documentService.openDocumentV2(view: view),
      ),
    );
    return state.copyWith(
      loadingState: DocumentLoadingState.finish(result),
    );
  }

  Future<void> _initAppFlowyEditorState(DocumentDataPB2 data) async {
    prettyPrintJson(data.toProto3Json());

    final document = data.toDocument();
    final editorState = EditorState(document: document);
    this.editorState = editorState;

    // subscribe to the document change from the editor
    _subscription = editorState.transactionStream.listen((transaction) async {
      await _transactionAdapter.apply(transaction, editorState);
    });

    // output the log from the editor when debug mode
    if (kDebugMode) {
      editorState.logConfiguration.handler = (log) {
        Log.debug(log);
      };
    }
  }
}

@freezed
class DocumentEvent with _$DocumentEvent {
  const factory DocumentEvent.initial() = Initial;
  const factory DocumentEvent.deleted() = Deleted;
  const factory DocumentEvent.restore() = Restore;
  const factory DocumentEvent.restorePage() = RestorePage;
  const factory DocumentEvent.deletePermanently() = DeletePermanently;
}

@freezed
class DocumentState with _$DocumentState {
  const factory DocumentState({
    required DocumentLoadingState loadingState,
    required bool isDeleted,
    required bool forceClose,
    UserProfilePB? userProfilePB,
  }) = _DocumentState;

  factory DocumentState.initial() => const DocumentState(
        loadingState: _Loading(),
        isDeleted: false,
        forceClose: false,
        userProfilePB: null,
      );
}

@freezed
class DocumentLoadingState with _$DocumentLoadingState {
  const factory DocumentLoadingState.loading() = _Loading;
  const factory DocumentLoadingState.finish(
    Either<FlowyError, DocumentDataPB2> successOrFail,
  ) = _Finish;
}

/// Uses to adjust the data structure between the editor and the backend.
class TransactionAdapter {
  TransactionAdapter({
    required this.documentId,
    required this.documentService,
  });

  final DocumentService documentService;
  final String documentId;

  Future<void> apply(Transaction transaction, EditorState editorState) async {
    final actions = transaction.operations
        .map((op) => op.toBlockAction(editorState))
        .whereNotNull()
        .expand((element) => element);
    Log.debug('actions => $actions');
    await documentService.applyAction(
      documentId: documentId,
      actions: actions,
    );
  }
}

extension on Operation {
  List<BlockActionPB> toBlockAction(EditorState editorState) {
    final List<BlockActionPB> actions = [];
    final op = this;
    if (op is InsertOperation) {
      Node? previousNode;
      for (final node in op.nodes) {
        final parentId = node.parent?.id ??
            editorState.getNodeAtPath(op.path.parent)?.id ??
            '';
        final prevId = previousNode?.id ??
            node.previous?.id ??
            editorState.getNodeAtPath(op.path.previous)?.id ??
            '';
        assert(parentId.isNotEmpty && prevId.isNotEmpty);
        final payload = BlockActionPayloadPB()
          ..block = node.toBlock()
          ..parentId = parentId
          ..prevId = prevId;
        assert(parentId.isNotEmpty);
        actions.add(
          BlockActionPB()
            ..action = BlockActionTypePB.Insert
            ..payload = payload,
        );
        previousNode = node;
      }
    } else if (op is UpdateOperation) {
      // if the attributes are both empty, we don't need to update
      if (const DeepCollectionEquality()
          .equals(op.attributes, op.oldAttributes)) {
        return actions;
      }
      final node = editorState.getNodeAtPath(op.path);
      if (node == null) {
        assert(false, 'node not found at path: ${op.path}');
        return actions;
      }
      final parentId = node.parent?.id ??
          editorState.getNodeAtPath(op.path.parent)?.id ??
          '';
      assert(parentId.isNotEmpty);
      final payload = BlockActionPayloadPB()
        ..block = node.toBlock()
        ..parentId = parentId;
      actions.add(
        BlockActionPB()
          ..action = BlockActionTypePB.Update
          ..payload = payload,
      );
    } else if (op is DeleteOperation) {
      // TODO: support deleting multiple nodes
      for (final node in op.nodes) {
        final parentId = node.parent?.id ??
            editorState.getNodeAtPath(op.path.parent)?.id ??
            '';
        final payload = BlockActionPayloadPB()
          ..block = node.toBlock()
          ..parentId = parentId;
        assert(parentId.isNotEmpty);
        actions.add(
          BlockActionPB()
            ..action = BlockActionTypePB.Delete
            ..payload = payload,
        );
      }
    }
    return actions;
  }
}
