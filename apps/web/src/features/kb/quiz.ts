/** A guide's quiz as the editor holds it, and as it's saved (public.sop_quizzes, checked by private.valid_quiz). */
import { t } from "@/lib/i18n";


export interface QuizDraft { question: string; options: string[]; answer: number | null }
export interface SavedQuestion { question: string; options: string[]; answer: number }

export const MAX_QUESTIONS = 10;
export const MAX_OPTIONS = 5;

export const blankQuestion = (): QuizDraft => ({ question: "", options: ["", ""], answer: null });

/**
 * The quiz ready to save: questions and answers trimmed, empty answers dropped (the right one's
 * place following), or what to fix first, in words for the person writing it.
 */
export function cleanQuiz(drafts: readonly QuizDraft[]): { questions: SavedQuestion[] } | { problem: string } {
  const questions: SavedQuestion[] = [];
  for (const [i, q] of drafts.entries()) {
    const n = i + 1;
    const question = q.question.trim();
    if (!question) return { problem: t("Write question {number}, or remove it.", { number: n }) };
    const kept = q.options.map((o, j) => ({ text: o.trim(), j })).filter((o) => o.text);
    if (kept.length < 2) return { problem: t("Question {number} needs at least two answers.", { number: n }) };
    const answer = kept.findIndex((o) => o.j === q.answer);
    if (answer < 0) return { problem: t("Pick the right answer for question {number}.", { number: n }) };
    questions.push({ question: question.slice(0, 300), options: kept.map((o) => o.text.slice(0, 200)), answer });
  }
  return { questions };
}
